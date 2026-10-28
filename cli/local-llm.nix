# Local LLM lab: ollama on the RTX 2060 plus a bare bones Open WebUI chat.
#
# `llm-lab` starts both services. Pull any model after (`ollama pull ...`),
# then chat at http://127.0.0.1:6969. Personas go in the per-chat
# System Prompt box.
#
# `llm-lab status` shows services, endpoints, dGPU, and loaded models.
# `llm-lab stop` shuts both down and frees VRAM and RAM.
#
# Nothing autostarts at login, so idle RAM and VRAM stay free.
{ config, lib, pkgs, pkgs-unstable-small-unfree, ... }:

let
  ollamaUrl = "http://127.0.0.1:11434";
  webuiPort = 6969;
  webuiUrl = "http://127.0.0.1:${toString webuiPort}";

  llm-lab = pkgs.writeShellScriptBin "llm-lab" ''
    set -euo pipefail

    OLLAMA_URL="${ollamaUrl}"
    WEBUI_URL="${webuiUrl}"
    OLLAMA_BIN="${pkgs-unstable-small-unfree.ollama-cuda}/bin/ollama"
    SYSTEMCTL="${pkgs.systemd}/bin/systemctl --user"
    CURL="${pkgs.curl}/bin/curl -sf"

    case "''${1:-start}" in
    stop)
      $SYSTEMCTL stop open-webui.service ollama.service
      echo "llm-lab: stopped. VRAM and RAM are free again."
      ;;
    status)
      echo "ollama service: $($SYSTEMCTL is-active ollama.service || true)"
      echo "webui service: $($SYSTEMCTL is-active open-webui.service || true)"
      if $CURL "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
        echo "ollama api: up ($OLLAMA_URL)"
      else
        echo "ollama api: down"
      fi
      if [ "$($CURL -o /dev/null -w "%{http_code}" "$WEBUI_URL/" 2>/dev/null || echo 000)" = "200" ]; then
        echo "webui chat: up ($WEBUI_URL)"
      else
        echo "webui chat: down"
      fi
      if command -v nvidia-smi >/dev/null && GPU=$(nvidia-smi -L 2>/dev/null | head -n 1) && [ -n "$GPU" ]; then
        echo "dgpu: $GPU"
      else
        echo "dgpu: off (powersave?)"
      fi
      "$OLLAMA_BIN" ps 2>/dev/null || echo "no models loaded"
      ;;
    start)
      $SYSTEMCTL start ollama.service open-webui.service

      for i in $(seq 1 60); do
        if $CURL "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
          break
        fi
        if [ "$i" -eq 60 ]; then
          echo "llm-lab: ollama did not answer at $OLLAMA_URL after 60s" >&2
          exit 1
        fi
        sleep 1
      done

      # The dGPU sleeps in powersave mode, and ollama would quietly use CPU.
      if ! command -v nvidia-smi >/dev/null || ! nvidia-smi -L >/dev/null 2>&1; then
        echo "llm-lab: note: dGPU not visible (powersave mode?). Switch to performance mode, then: systemctl --user restart ollama.service"
      fi

      "$OLLAMA_BIN" ps
      echo "llm-lab: pull a model with: ollama pull <model>"
      echo "llm-lab: chat at $WEBUI_URL (set the System Prompt box per chat to test personas)"
      ;;
    *)
      echo "usage: llm-lab [start|stop|status]" >&2
      exit 1
      ;;
    esac
  '';
in
{
  services.ollama = {
    enable = true;
    package = pkgs-unstable-small-unfree.ollama-cuda;
    acceleration = "cuda";
    host = "127.0.0.1";
    port = 11434;
    environmentVariables = {
      CUDA_VISIBLE_DEVICES = "0";
      # 16k context fits small models in 6GB VRAM. If a big model OOMs,
      # drop CONTEXT_LENGTH back to 4096.
      OLLAMA_KEEP_ALIVE = "5m";
      OLLAMA_MAX_LOADED_MODELS = "1";
      OLLAMA_NUM_PARALLEL = "1";
      OLLAMA_CONTEXT_LENGTH = "16384";
      OLLAMA_KV_CACHE_TYPE = "q8_0";
      OLLAMA_FLASH_ATTENTION = "1";
    };
  };

  # Stay off at login; llm-lab starts this when you want it.
  systemd.user.services.ollama.Install.WantedBy = lib.mkForce [ ];

  systemd.user.services.open-webui = {
    Unit = {
      Description = "Open WebUI, minimal chat for local ollama";
      After = [
        "network.target"
        "ollama.service"
      ];
    };
    Service = {
      ExecStart = "${pkgs.open-webui}/bin/open-webui serve --host 127.0.0.1 --port ${toString webuiPort}";
      Restart = "on-failure";
      Environment = [
        "DATA_DIR=${config.home.homeDirectory}/.local/share/open-webui/data"
        "WEBUI_URL=${webuiUrl}"
        "OLLAMA_BASE_URL=${ollamaUrl}"
        # No login screen. Only applies to a fresh DATA_DIR. If WebUI ever
        # complains it can't turn auth off, run `llm-lab stop`, wipe DATA_DIR,
        # and start over.
        "WEBUI_AUTH=False"
        # Env always wins over the DB, so edits here stick.
        "ENABLE_PERSISTENT_CONFIG=False"
        # No side LLM calls.
        "ENABLE_TITLE_GENERATION=False"
        "ENABLE_FOLLOW_UP_GENERATION=False"
        "ENABLE_TAGS_GENERATION=False"
        "ENABLE_SEARCH_QUERY_GENERATION=False"
        "ENABLE_RETRIEVAL_QUERY_GENERATION=False"
        "ENABLE_CONTEXT_COMPACTION=False"
        "ENABLE_MEMORIES=False"
        "ENABLE_CODE_INTERPRETER=False"
        "ENABLE_CODE_EXECUTION=False"
        "ENABLE_AUTOMATIONS=False"
        "ENABLE_NOTES=False"
        "ENABLE_COMMUNITY_SHARING=False"
        "ENABLE_MESSAGE_RATING=False"
        "ENABLE_OPENAI_API=False"
        "OFFLINE_MODE=True"
        "ENABLE_VERSION_UPDATE_CHECK=False"
        "HF_HUB_OFFLINE=1"
        "DO_NOT_TRACK=True"
        "SCARF_NO_ANALYTICS=True"
        "ANONYMIZED_TELEMETRY=False"
      ];
    };
  };

  home.packages = [ llm-lab ];
}
