# Crawl4AI: a real browser for pages a plain HTTP fetch cannot read, behind one
# small API that returns text, a screenshot and the page's images as files.
#
# Why a container and not `buildPythonPackage` (the only other option short of
# writing the crawler myself): Crawl4AI 0.9.6 pins `patchright` (a Playwright
# fork), `playwright>=1.64.1` (nixpkgs ships 1.59) and `unclecode-litellm`, a
# private fork of litellm. nixpkgs has none of the three, and each one is a
# browser or an HTTP client with its own packaging story, so a pure build needs
# three forks packaged before the first page loads. The image carries its
# browsers and the exact versions the code expects. The cost is honest: the
# image is a 2.3 GB opaque blob pulled from Docker Hub, not a nix build, tagged
# below and moved by hand. Everything the tailnet sees is still ours, and it is
# the numbered interface below, not the container's.
#
# The caller uses apps/crawl4ai/fetch.py, which is the only listener the tailnet
# reaches; it binds every address and the firewall rule at the bottom is what
# keeps the LAN out:
#
#   POST /fetch {"url": "...", "want": ["text"], "query": "..."}
#     -> {"text", "text_file", "images": [absolute paths],
#         "screenshot": absolute path|null, "status", "fetched_at", ...}
#
#   GET /health
#   GET /artifacts/<run>/<file>
#
# The container itself listens on 127.0.0.1 only, in the host's network
# namespace (see the comment on the container below), and needs the marker
# token in the let below; fetch.py is its only caller.
#
# The LLM hook is Crawl4AI's own content filter, reached with `query`. It is off
# until ~/.config/crawl4ai/llm.env holds an OPENAI_API_KEY and `models` names at
# least one model; both are read per request, so the free model list can change
# without a rebuild or a restart. The container reads the key once at start, so
# a new key needs `systemctl restart podman-crawl4ai`. With neither file the
# service still fetches pages and filters them by keyword.
{
  config,
  hostConfig,
  lib,
  pkgs,
  ...
}:
let
  # Bump this by hand. There is no update script because the image is not a nix
  # build: `curl -s https://hub.docker.com/v2/repositories/unclecode/crawl4ai/tags`
  # lists the tags, and 0.9.6 is the one this module was tested against.
  # Tag and amd64 manifest digest: the tag can move, the digest cannot, and the
  # box only ever pulls one architecture.
  image = "docker.io/unclecode/crawl4ai:0.9.6@sha256:14bcdc57464635d7e1467753eb540e438b3f7b21b0423c8b69fa6dbf4f40658f";

  containerPort = 11235;
  apiPort = 10002;

  # The container's API requires a bearer token even on loopback, and its
  # entrypoint decides the bind address from whether one is set. GUNICORN_BIND
  # overrides that decision, so with both set the API needs a token and still
  # listens on 127.0.0.1 only. The value stays a marker on purpose: a credential
  # that lives in the store is not one, and the real boundary is the bind plus
  # the fact that nothing but this host's loopback can route to it.
  localToken = "loopback-marker";

  configDir = "${hostConfig.user.home}/.config/crawl4ai";
  workspace = "${hostConfig.dotsDir}/.tmp/crawl4ai";
in
{
  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.crawl4ai = {
    inherit image;

    # No published port and the host's network namespace, on purpose: the
    # image's entrypoint decides its bind address from CRAWL4AI_API_TOKEN, and
    # a bridge publish answered "no route to host" on this box (netavark's DNAT
    # never delivered). With GUNICORN_BIND pinned to loopback and the firewall
    # as the only other filter, the API is a loopback service and fetch.py is
    # its only caller.
    #
    # The namespace is shared, so what the image starts besides gunicorn lands
    # in the host's: redis binds 127.0.0.1:6379 (with a password the entrypoint
    # generates) and Chromium runs with upstream's --no-sandbox, because the
    # image has no usable sandbox as a non-root user. Podman's own seccomp and
    # capabilities still apply; 6379 is free on this host today and would have
    # to move if something else ever wants it.
    environment = {
      CRAWL4AI_API_TOKEN = localToken;
      GUNICORN_BIND = "127.0.0.1:${toString containerPort}";
      CRAWL4AI_PORT = toString containerPort;
      # OpenCode Go speaks OpenAI's chat API. The key is in llm.env, which
      # -e does not override; only the model name travels per request.
      OPENAI_BASE_URL = "https://opencode.ai/inference/go/openai/v1";
      # The banner is upstream's advertisement, not something to log on every
      # start.
      CRAWL4AI_NO_CLOUD_NOTICE = "1";
    };

    # Created by the unit below when it does not exist, so the container never
    # fails on a missing file. podman reads it as root, which is why it can stay
    # 0600 in the user's home.
    environmentFiles = [ "${configDir}/llm.env" ];

    extraOptions = [
      "--network=host"
      # Chromium's shared memory, as upstream's docker run documents. Without
      # it a full-page render of a long page can crash the renderer.
      "--shm-size=1g"
      "--security-opt=no-new-privileges"
    ];
  };

  # A pull on first start, on the box's own connection, and a restart when the
  # switch moves the tag. Nothing else about the image is managed.
  #
  # systemd gives up on a unit after five starts in ten seconds, and a pull that
  # fails because the registry is unreachable is exactly that: retrying until
  # the next switch is better than a container that stays down until someone
  # looks. Ten seconds between tries, or a failing pull would spin.
  systemd.services.podman-crawl4ai.unitConfig.StartLimitIntervalSec = 0;
  systemd.services.podman-crawl4ai.serviceConfig.RestartSec = "10s";

  # --env-file fails the container if the file is missing, and the file lives in
  # a home the first system switch of a host has not populated yet. Creating it
  # empty is enough: home.nix fills it, and the fetch API reads an empty key as
  # "no LLM".
  systemd.services.podman-crawl4ai.serviceConfig.ExecStartPre = lib.mkAfter [
    (pkgs.writeShellScript "crawl4ai-key-file" ''
      ${pkgs.coreutils}/bin/install -d -m 0755 -o ${hostConfig.user.name} ${configDir}
      if [ ! -e ${configDir}/llm.env ]; then
        ${pkgs.coreutils}/bin/install -m 0600 -o ${hostConfig.user.name} /dev/null ${configDir}/llm.env
      fi
    '')
  ];

  systemd.services.crawl4ai-fetch = {
    description = "Crawl4AI fetch API: page text, screenshots and images as files";
    wantedBy = [ "multi-user.target" ];
    # Not Requires: a fetch while the container restarts answers 502 with the
    # reason, which is more useful than the shim being down too.
    wants = [ "podman-crawl4ai.service" ];
    after = [
      "network.target"
      "podman-crawl4ai.service"
    ];
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      User = hostConfig.user.name;
      ExecStart = "${pkgs.python3}/bin/python3 ${./fetch.py}";
      Restart = "always";
      RestartSec = 2;
      Environment = [
        "CRAWL4AI_UPSTREAM=http://127.0.0.1:${toString containerPort}"
        "CRAWL4AI_API_TOKEN=${localToken}"
        "CRAWL4AI_WORKSPACE=${workspace}"
        "CRAWL4AI_MODELS=${configDir}/models"
        "CRAWL4AI_LLM_ENV=${configDir}/llm.env"
        "CRAWL4AI_PORT=${toString apiPort}"
        "PYTHONDONTWRITEBYTECODE=1"
      ];
      # Nothing in the home is readable: the process needs two files in one
      # directory and one scratch tree, and a bug in a network-facing HTTP
      # handler should not hand out ~/.ssh. ProtectHome=tmpfs hides the home,
      # the read-only bind brings back the two config files, and the rw bind is
      # the only place anything is written.
      ProtectSystem = "strict";
      ProtectHome = "tmpfs";
      BindReadOnlyPaths = [ "-${configDir}" ];
      BindPaths = [ "${hostConfig.dotsDir}/.tmp" ];
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      LockPersonality = true;
    };
  };

  # Only the scratch root is declared here. systemd-tmpfiles refuses to fix
  # ownership below a directory that is not owned by the account it would hand
  # the path to, so the fetch API creates crawl4ai/runs inside .tmp itself, as
  # its own user, at startup. This rule also has to run before the unit, since
  # its bind mount would otherwise point at nothing.
  systemd.tmpfiles.rules = [
    "d ${hostConfig.dotsDir}/.tmp 0755 ${hostConfig.user.name} - -"
  ];

  # The tailnet is the only way in, as for every service this repo publishes.
  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
    lib.mkIf config.services.tailscale.enable
      [ apiPort ];
}
