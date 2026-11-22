# SearXNG, the meta search engine the agents query instead of a built-in web
# search, which cannot tell a release date from a month of blog posts.
#
# The HTTP API is SearXNG's own:
#
#   GET /search?q=nixos+26.11+release+date&format=json
#       &categories=general&language=en
#
# JSON is not one of the default formats: without `json` in `search.formats`
# the same request answers 403. `site:` passes through to the engines that
# honour it, so a caller can narrow a search itself. `categories=it` is what
# reaches the GitHub issue engine below.
#
# `time_range` narrows the query to the engines that declare support for it and
# searx skips the rest. Google and duckduckgo declare it, but they are the two
# that refuse this address, so a time_range request answers with nothing here.
# Put freshness in the words of the query ("release date", "latest") instead.
#
# The port is opened only on the tailnet interface, and the service binds every
# address so the tailnet one is among them; the firewall is what keeps the LAN
# and every other interface out, without naming an address tailscaled assigns.
# Loopback is always reachable, by design of the firewall, and is not a way in
# from anywhere else.
#
# The rate limiter is on, which needs a valkey instance of its own
# (`redisCreateLocally`; the setting key is spelled `valkey` since the fork).
# It treats every caller it does not recognise as a bot, and curl is not a
# browser, so the tailnet range is passed through by address instead. That also
# means no client of this instance is ever limited: everything that can reach
# the port is in one of the passed ranges. The limiter is there for the case
# where the firewall rule ever grows a range it does not cover.
#
# The engines scrape, and this box's egress is a shared residential address
# that the scrapers treat as a bot: google answers "access denied", duckduckgo
# and startpage serve a challenge, and bing alternates between the right pages
# and an SEO farm for the same query. That is why the Jina engine is wired for a
# key (free, from jina.ai, no signup): a JSON search API does not have to be
# scraped. See the comment on `engines` below.
#
# Engine API keys go in `secretFile` as NAME=value and are referenced as `$NAME`
# in `settings` (envsubst runs over the file at start, so the value stays out of
# the store). `secret_key` is generated on first start for the same reason.
{
  config,
  hostConfig,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}:
let
  port = 8888;
  secretFile = "/var/lib/searxng/secrets.env";

  # The settings and the limiter file are rendered into /run/searx at start, so
  # neither unit's ExecStart changes when they do in a way systemd can compare.
  # This store path holds both, and both units list it as a restart trigger.
  # searx-init regenerates the files; searx reloads them.
  settingsTrigger = pkgs.writeText "searx-settings-trigger" (
    builtins.toJSON {
      settings = config.services.searx.settings;
      limiter = config.services.searx.limiterSettings;
    }
  );
in
{
  services.searx = {
    enable = true;

    # The engine scrapers track the sites they scrape, so the package follows
    # unstable even though the host does not: the stable build's Google and Bing
    # parsers answered with other pages' results, and one from last month
    # answers correctly. The module here is the host's, which is fine; it only
    # renders the settings the package reads.
    package = pkgs-unstable.searxng;

    settings = {
      # The defaults are a hundred engines, many of which need a key or block a
      # datacenter address. These are the ones this instance keeps; the ones
      # that answer are bing, github, stackoverflow and wikipedia.
      use_default_settings.engines.keep_only = [
        "google"
        "duckduckgo"
        "bing"
        "wikipedia"
        "github"
        "stackoverflow"
        "jina"
      ];

      # keep_only keeps an engine's entry but not its enabled state: bing and
      # google both ship disabled, and bing is the one that answers at all from
      # here. Google is enabled too, so the "access denied" it returns shows up
      # in unresponsive_engines instead of hiding an engine that would work
      # from a better egress. Jina is the durable answer: a JSON search API with
      # a free key from jina.ai (no signup), instead of one more scraper. With
      # no $JINA_API_KEY in the secret file its setup refuses, and searx drops
      # the engine rather than failing to start.
      engines = [
        {
          name = "bing";
          disabled = false;
        }
        {
          name = "google";
          disabled = false;
        }
        {
          name = "jina";
          inactive = false;
          api_key = "$JINA_API_KEY";
        }
        # The engines above index pages, not issue trackers, so an error string
        # from a bug report is invisible to them. This is searx's generic JSON
        # engine pointed at GitHub's issue search, which does index bodies: the
        # query `"makeVimPackageInfo"` with categories=it finds the nixvim
        # issue. It stays out of `general` so a web query is not padded with
        # issues about the words in it.
        {
          name = "github issues";
          engine = "json_engine";
          categories = [ "it" ];
          shortcut = "ghi";
          search_url = "https://api.github.com/search/issues?q={query}&per_page=10";
          results_query = "items";
          url_query = "html_url";
          title_query = "title";
          # GitHub's search API returns no snippet, and a body would be
          # kilobytes per hit; the creation date is the one short fact worth
          # carrying.
          content_query = "created_at";
          paging = false;
        }
      ];

      general.instance_name = "searxng";

      server = {
        bind_address = "0.0.0.0";
        port = port;
        # Only this host answers to this name, and every caller is on the
        # tailnet, where it resolves.
        base_url = "http://${hostConfig.hostName}:${toString port}/";
        secret_key = "$SEARXNG_SECRET";
        limiter = true;
        public_instance = false;
        image_proxy = true;
      };

      search = {
        formats = [
          "html"
          "json"
        ];
        # An autocomplete request would send every keystroke to Google.
        autocomplete = "";
        safe_search = 0;
        # This box's egress geolocates to India, and bing answers an
        # unlocalised request with adult and unrelated pages around the real
        # result. With the language pinned to English those pages are only
        # unrelated. Callers do not have to pass `language`; the lock below
        # means they cannot change it either.
        default_lang = "en";
      };

      # SearXNG otherwise takes the language from the request or the cookie and
      # defaults to "auto", which is what let the engines localise to the
      # geolocated country. One instance, one language.
      preferences.lock = [ "language" ];
    };

    environmentFile = secretFile;
    redisCreateLocally = true;
    limiterSettings.botdetection.ip_lists.pass_ip = [
      "127.0.0.0/8"
      "::1"
      # Tailscale's CGNAT range: every tailnet peer, and nothing else, because
      # this is the only interface the port is open on.
      "100.64.0.0/10"
    ];
  };

  # Runs before searx-init reads the file. `-s` keeps an existing secret: a new
  # one on every switch would invalidate nothing visible, but it would rewrite
  # a file an operator may have written keys into.
  systemd.services.searxng-secret = {
    description = "Generate the SearXNG secret on first start";
    wantedBy = [ "multi-user.target" ];
    before = [ "searx-init.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0750 -o root -g searx /var/lib/searxng
      if [ ! -s ${secretFile} ]; then
        umask 027
        printf 'SEARXNG_SECRET=%s\n' "$(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${secretFile}
      fi
      chown root:searx ${secretFile}
      chmod 0640 ${secretFile}
    '';
  };
  systemd.services.searx-init.requires = [ "searxng-secret.service" ];
  systemd.services.searx-init.after = [ "searxng-secret.service" ];

  systemd.services.searx-init.restartTriggers = [ settingsTrigger ];
  systemd.services.searx.restartTriggers = [ settingsTrigger ];

  # SearXNG reads limiter.toml from the directory of SEARXNG_SETTINGS_PATH,
  # which the module points at /run/searx/settings.yml, while it writes
  # limiter.toml to /etc/searxng. Without the link the limiter silently runs on
  # its built-in defaults and the pass_ip list above never applies.
  systemd.services.searx-init.serviceConfig.ExecStartPost = "${pkgs.coreutils}/bin/ln -sf ${
    config.environment.etc."searxng/limiter.toml".source
  } /run/searx/limiter.toml";

  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
    lib.mkIf config.services.tailscale.enable
      [ port ];
}
