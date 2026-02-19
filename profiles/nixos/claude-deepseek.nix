{
  self,
  config,
  pkgs,
  ...
}:

let
  claude-ds = pkgs.writeShellScriptBin "claude-ds" ''
    export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
    export ANTHROPIC_AUTH_TOKEN="$(cat ${config.age.secrets.deepseekApiKey.path})"
    export ANTHROPIC_MODEL="deepseek-reasoner"
    export ANTHROPIC_SMALL_FAST_MODEL="deepseek-chat"
    export API_TIMEOUT_MS="600000"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
    export CLAUDE_CODE_ATTRIBUTION_HEADER="0"       # changing billing header in system prompt busts prefix cache
    export DISABLE_PROMPT_CACHING="1"                # cache_control breakpoints are Anthropic-specific
    export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1" # anthropic-beta headers may be rejected
    exec claude "$@"
  '';
in
{
  age.secrets.deepseekApiKey = {
    file = "${self}/secrets/deepseek-api-key.age";
    owner = "cjv";
    mode = "0400";
  };

  environment.systemPackages = [ claude-ds ];
}
