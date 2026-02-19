{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

# STATE:
# - Download model before starting the service:
#     mkdir -p /persist/models
#     nix shell nixpkgs#python3Packages.huggingface-hub -c hf download \
#       ubergarm/Qwen3-Coder-30B-A3B-Instruct-GGUF \
#       Qwen3-Coder-30B-A3B-Instruct-IQ4_KSS.gguf \
#       --local-dir /persist/models
# - Download minja-compatible chat template (fixes reject filter crash):
#     nix shell nixpkgs#python3Packages.huggingface-hub -c hf download \
#       unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
#       template \
#       --local-dir /persist/models
#

let
  cfg = config.services.ik-llama;
  model = "qwen3-coder-30b-a3b";
  llamaPort = 8012;
  litellmPort = 4000;
  modelPath = "/persist/models/Qwen3-Coder-30B-A3B-Instruct-IQ4_KSS.gguf";

  # ik_llama.cpp: upstream bug — package.nix returns env = [] (a list) instead
  # of {} when useRocm is false. mkDerivation requires env to be an attrset.
  patchedStdenv = pkgs.stdenv // {
    mkDerivation = fnOrAttrs:
      pkgs.stdenv.mkDerivation (
        if builtins.isFunction fnOrAttrs then
          finalAttrs:
          let
            result = fnOrAttrs finalAttrs;
          in
          result // { env = if builtins.isList (result.env or { }) then { } else result.env; }
        else
          fnOrAttrs
          // { env = if builtins.isList (fnOrAttrs.env or { }) then { } else fnOrAttrs.env; }
      );
  };

  ik-llama =
    (pkgs.callPackage "${inputs.ik-llama}/.devops/nix/package.nix" {
      effectiveStdenv = patchedStdenv;
    }).overrideAttrs
      (old: {
        cmakeFlags = old.cmakeFlags ++ [
          (lib.cmakeBool "GGML_LTO" true)
        ];
      });

  litellmConfig = pkgs.writeText "litellm-config.yaml" (builtins.toJSON {
    model_list = [
      {
        model_name = model;
        litellm_params = {
          model = "openai/${model}";
          api_base = "http://127.0.0.1:${toString llamaPort}/v1";
          api_key = "not-needed";
          timeout = 600;
        };
      }
    ];
    litellm_settings = {
      drop_params = true; # strip Anthropic-specific params (thinking, cache_control, etc.)
    };
  });
in
{
  options.services.ik-llama = {
    threads = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "Number of threads for inference (set to physical core count).";
    };
  };

  config = {
    services = {
      # OpenAI-compatible API (used by Open WebUI, qwen-code, opencode, etc.)
      nginx.virtualHosts."llm.vaz.ovh" = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString llamaPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };
      };

      # Anthropic Messages API (used by Claude Code via claude-qwen wrapper)
      nginx.virtualHosts."llm-anthropic.vaz.ovh" = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString litellmPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };
      };

      llama-cpp = {
        enable = true;
        package = ik-llama;
        model = modelPath;
        host = "127.0.0.1";
        port = llamaPort;
        extraFlags = [
          "-t" (toString cfg.threads)
          "--threads-batch" (toString cfg.threads)

          # Context: 1 slot × 128K with Q8 KV
          "-c" "131072"
          "--cache-type-k" "q8_0"
          "--cache-type-v" "q8_0"

          # Batch sizes
          "-b" "2048"
          "-ub" "512"

          # Lock model in RAM (prevents swapping under memory pressure)
          "--mlock"

          # Jinja templates: required for Qwen3-Coder chat format and tool use.
          # Override the GGUF-embedded template with Unsloth's minja-compatible version
          # (ubergarm's template uses `| reject()` which crashes ik_llama.cpp's minja engine).
          "--jinja"
          "--chat-template-file" "/persist/models/template"

          # ik_llama.cpp: flash attention
          "-fa" "auto"

          # ik_llama.cpp: repack tensors into interleaved format at load time.
          # One-time cost at startup, faster inference thereafter.
          "--run-time-repack"

          # Qwen-recommended sampling defaults (overridable per-request by clients)
          "--temp" "0.7"
          "--top-p" "0.80"
          "--top-k" "20"
          "--min-p" "0.0"
          "--repeat-penalty" "1.05"

          # Single slot: ik_llama.cpp's "-fa auto" (optimized flash attention) crashes
          # with GGML_ASSERT(S > 0) in iqk_fa_templates.h when --parallel > 1.
          "--parallel" "1"

          # Clean model name for /v1/models and client requests
          "--alias" model
        ];
      };
    };

    # --mlock needs unlimited memlock
    systemd.services.llama-cpp.serviceConfig = {
      LimitMEMLOCK = "infinity";
      RestartSec = lib.mkForce "10s";
    };

    # litellm: translates Anthropic Messages API -> OpenAI Chat Completions API
    # so Claude Code (which only speaks Anthropic) can use the llama-server.
    systemd.services.litellm = {
      description = "LiteLLM Proxy - Anthropic-to-OpenAI API translation";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "llama-cpp.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.unstable.litellm}/bin/litellm --config ${litellmConfig} --host 127.0.0.1 --port ${toString litellmPort}";
        Restart = "on-failure";
        RestartSec = "5s";
        DynamicUser = true;
      };
    };
  };
}
