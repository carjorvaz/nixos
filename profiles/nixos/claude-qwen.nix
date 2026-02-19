{ pkgs, ... }:

# Claude Code wrapper pointing at the self-hosted Qwen on pius.
# Requires litellm.nix on pius (Anthropic API -> OpenAI API translation).
#
# Caveats:
# - Claude Code's agentic tool-use loop depends on structured tool calling.
#   Qwen handles this reasonably well but expect rough edges vs. real Claude.
# - Extended thinking, prompt caching, and other Anthropic-specific features
#   are silently ignored.

let
  model = "qwen3-coder-30b-a3b"; # --alias in llama-server.nix

  claude-qwen = pkgs.writeShellScriptBin "claude-qwen" ''
    export ANTHROPIC_BASE_URL="https://llm-anthropic.vaz.ovh"
    export ANTHROPIC_AUTH_TOKEN="not-needed"
    export ANTHROPIC_MODEL="${model}"
    export ANTHROPIC_SMALL_FAST_MODEL="${model}"
    export API_TIMEOUT_MS="600000"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
    export CLAUDE_CODE_ATTRIBUTION_HEADER="0"       # changing billing header in system prompt busts KV cache
    export DISABLE_PROMPT_CACHING="1"                # cache_control breakpoints are Anthropic-specific
    export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1" # anthropic-beta headers may be rejected
    exec claude "$@"
  '';
in
{
  environment.systemPackages = [ claude-qwen ];
}
