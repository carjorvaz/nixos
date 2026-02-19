{ pkgs, ... }:

let
  # llama-server on pius (see llama-server.nix)
  baseURL = "https://llm.vaz.ovh/v1";
  model = "qwen3-coder-30b-a3b"; # --alias in llama-server.nix
  contextWindow = 131072; # -c in llama-server.nix
in
{
  environment.systemPackages = [
    pkgs.llm-agents.qwen-code
    pkgs.llm-agents.opencode
  ];

  home-manager.users.cjv.home.file.".qwen/settings.json".text = builtins.toJSON {
    "$version" = 3; # prevent Qwen from trying to write version to read-only Nix store
    security.auth = {
      selectedType = "openai";
      apiKey = "not-needed";
      baseUrl = baseURL; # Qwen Code expects camelCase "baseUrl", not "baseURL"
    };
    model = {
      name = model;
      generationConfig.timeout = 600000; # 10 minutes — local CPU inference is slow
    };
  };

  home-manager.users.cjv.xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
    provider = {
      local-qwen = {
        npm = "@ai-sdk/openai-compatible";
        name = "Qwen3 Coder (pius)";
        options = {
          inherit baseURL;
          apiKey = "not-needed";
        };
        models = {
          ${model} = {
            name = "Qwen3 Coder 30B A3B";
            limit.context = contextWindow;
            limit.output = 16384;
          };
        };
      };
    };
    model = "local-qwen/${model}";
    small_model = "local-qwen/${model}"; # title generation — avoid built-in opencode/gpt-5-nano
  };
}
