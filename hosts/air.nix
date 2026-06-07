{
  self,
  lib,
  pkgs,
  inputs,
  config,
  ...
}:

let
  key = key_code: { inherit key_code; };
  topCaseKey = apple_vendor_top_case_key_code: { inherit apple_vendor_top_case_key_code; };

  basicRemap = from: to: {
    type = "basic";
    from = from // {
      modifiers.optional = [ "any" ];
    };
    to = [ to ];
  };

  conditionedRemap = condition: from: to: (basicRemap from to) // {
    conditions = [ condition ];
  };

  swap = remap: a: b: [
    (remap a b)
    (remap b a)
  ];

  builtInKeyboardCondition = {
    type = "device_if";
    identifiers = [
      { is_built_in_keyboard = true; }
    ];
  };

  nonBuiltInKeyboardCondition = {
    type = "device_unless";
    identifiers = [
      { is_built_in_keyboard = true; }
    ];
  };

  allKeyboardModifierPolicy = [
    (basicRemap (key "caps_lock") (key "left_control"))
    (basicRemap (key "right_command") (key "right_option"))
  ];

  externalKeyboardModifierPolicy = swap
    (conditionedRemap nonBuiltInKeyboardCondition)
    (key "left_command")
    (key "left_option");

  builtInKeyboardModifierPolicy =
    (swap
      (conditionedRemap builtInKeyboardCondition)
      (topCaseKey "keyboard_fn")
      (key "left_control"));

  karabinerConfig = {
    global.show_in_menu_bar = false;

    profiles = [
      {
        name = "Default profile";
        selected = true;

        # Use complex modifications here so the built-in keyboard can stay
        # native while external keyboards still inherit the modifier policy.
        complex_modifications.rules = [
          {
            description = "Apply global modifier remaps";
            manipulators = allKeyboardModifierPolicy;
          }
          {
            description = "Swap fn and left control on the built-in keyboard";
            manipulators = builtInKeyboardModifierPolicy;
          }
          {
            description = "Apply modifier swaps to external keyboards only";
            manipulators = externalKeyboardModifierPolicy;
          }
        ];

        virtual_hid_keyboard.keyboard_type_v2 = "iso";
      }
    ];
  };

  karabinerJson = pkgs.writeText "karabiner.json" (builtins.toJSON karabinerConfig);

  karabinerConfigDir = pkgs.runCommandLocal "karabiner-config" { } ''
    mkdir -p "$out/assets/complex_modifications"
    cp ${karabinerJson} "$out/karabiner.json"
  '';

  fontconfigMacosConf = pkgs.writeText "fontconfig-macos-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <dir>/Library/Fonts</dir>
      <dir>/System/Library/Fonts</dir>
      <dir>~/Library/Fonts</dir>
    </fontconfig>
  '';

  hermesTerminalSudoCommentLine =
    "    # Local hosts with sudoers NOPASSWD should not be forced through the";
  hermesTerminalNativeSudoReplacement = lib.concatStringsSep "\n" [
    "    if os.environ.get(\"HERMES_DESKTOP_NATIVE_SUDO\") == \"1\" and not has_configured_password:"
    "        return command, None"
    ""
    hermesTerminalSudoCommentLine
  ];
  hermesGatewaySudoCallbackLine =
    "    set_sudo_password_callback(lambda: _block(\"sudo.request\", sid, {}, timeout=120))";
  hermesGatewayNativeSudoReplacement = lib.concatStringsSep "\n" [
    "    if os.environ.get(\"HERMES_DESKTOP_NATIVE_SUDO\") != \"1\":"
    "        set_sudo_password_callback(lambda: _block(\"sudo.request\", sid, {}, timeout=120))"
  ];

  # The Desktop sudo overlay cannot hand off to macOS Touch ID. Keep Desktop on
  # native sudo unless Hermes has been configured with an explicit SUDO_PASSWORD.
  hermesAgentSource = pkgs.applyPatches {
    name = "hermes-agent-native-sudo-source";
    src = inputs.hermes-agent;
    postPatch = ''
      substituteInPlace tools/terminal_tool.py \
        --replace-fail \
          ${lib.escapeShellArg hermesTerminalSudoCommentLine} \
          ${lib.escapeShellArg hermesTerminalNativeSudoReplacement}

      substituteInPlace tui_gateway/server.py \
        --replace-fail \
          ${lib.escapeShellArg hermesGatewaySudoCallbackLine} \
          ${lib.escapeShellArg hermesGatewayNativeSudoReplacement}
    '';
  };
  hermesAgentPackage = pkgs.callPackage "${hermesAgentSource}/nix/hermes-agent.nix" {
    inherit (inputs.hermes-agent.inputs) uv2nix pyproject-nix pyproject-build-systems;
    npm-lockfile-fix =
      inputs.hermes-agent.inputs.npm-lockfile-fix.packages.${pkgs.stdenv.hostPlatform.system}.default;
    rev = inputs.hermes-agent.rev or null;
  };
  # Hermes pins the Firecrawl SDK via lazy_deps; keep the Nix-managed wrapper
  # satisfying that exact pin so web_extract works with lazy installs disabled.
  hermesAgentFirecrawlPy = pkgs.python312Packages.firecrawl-py.overridePythonAttrs (_old: rec {
    version = "4.17.0";
    src = pkgs.fetchPypi {
      pname = "firecrawl_py";
      inherit version;
      hash = "sha256-m1fg+5G39xFoKoJd1k1RCQ/vnotU6v7njBQTPV3q7Vc=";
    };
    sourceRoot = null;
  });
  hermesAgentPythonPath = pkgs.python312Packages.makePythonPath [
    pkgs.python312Packages.ddgs
    hermesAgentFirecrawlPy
  ];
  hermesAgentBrowser = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";

  pipxFixed = pkgs.pipx.overridePythonAttrs (old: {
    # pipx 1.8.0's URL-specifier tests still expect packaging's older
    # no-space spelling around "@". packaging 26 keeps the canonical space,
    # which is harmless at runtime but breaks these string-exact tests.
    disabledTests = (old.disabledTests or [ ]) ++ [
      "test_fix_package_name"
      "test_parse_specifier_for_metadata"
    ];
  });

  hermesCliTools = pkgs.runCommandLocal "hermes-agent-cli-tools" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    mkdir -p "$out/bin"

    makeHermesWrapper() {
      local source="$1"
      local target="$2"
      makeWrapper "$source" "$target" \
        --prefix PYTHONPATH : ${lib.escapeShellArg hermesAgentPythonPath} \
        --set-default AGENT_BROWSER_EXECUTABLE_PATH ${lib.escapeShellArg hermesAgentBrowser}
    }

    makeHermesWrapper ${lib.escapeShellArg "${hermesAgentPackage}/bin/hermes"} "$out/bin/hermes-cli"

    for bin in hermes-agent hermes-acp; do
      source=${lib.escapeShellArg "${hermesAgentPackage}/bin"}/"$bin"
      if [ -e "$source" ]; then
        makeHermesWrapper "$source" "$out/bin/$bin"
      fi
    done
  '';

  hermesDesktopPackage = pkgs.callPackage ../pkgs/hermes-desktop.nix {
    inherit inputs;
    hermesAgent = hermesAgentPackage;
    hermesCliPath = "${hermesCliTools}/bin/hermes-cli";
  };

  hermesCommand = pkgs.writeShellApplication {
    name = "hermes";
    text = ''
      if [ "$#" -gt 0 ] && { [ "$1" = "desktop" ] || [ "$1" = "gui" ]; }; then
        shift
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --cwd)
              shift
              if [ "$#" -eq 0 ]; then
                echo "hermes desktop: --cwd requires a path" >&2
                exit 2
              fi
              export HERMES_DESKTOP_CWD="$1"
              ;;
            --cwd=*)
              export HERMES_DESKTOP_CWD="''${1#--cwd=}"
              ;;
            --fake-boot)
              export HERMES_DESKTOP_BOOT_FAKE=1
              ;;
            --ignore-existing)
              export HERMES_DESKTOP_IGNORE_EXISTING=1
              ;;
            --skip-build|--force-build|--source)
              echo "hermes desktop: $1 is unnecessary for the Nix-built desktop; ignoring it." >&2
              ;;
            --build-only)
              echo "hermes desktop: already built by Nix at ${lib.getExe hermesDesktopPackage}"
              exit 0
              ;;
            -h|--help)
              cat <<'HELP'
usage: hermes desktop [--cwd PATH] [--fake-boot] [--ignore-existing]

Launch the Nix-built Hermes Desktop app.

The upstream source-build flags (--skip-build, --force-build, --source,
--build-only) are not needed here because nix-darwin builds the Electron app.
You can also run: hermes-desktop
HELP
              exit 0
              ;;
            *)
              echo "hermes desktop: unsupported Nix wrapper argument: $1" >&2
              exit 2
              ;;
          esac
          shift
        done

        exec ${lib.getExe hermesDesktopPackage}
      fi

      exec ${lib.escapeShellArg "${hermesCliTools}/bin/hermes-cli"} "$@"
    '';
  };

  hermesAgent = pkgs.symlinkJoin {
    name = "hermes-agent-air";
    paths = [
      hermesCliTools
      hermesCommand
      hermesDesktopPackage
    ];
  };

  braveBpcExtensionId = "lkbebcjgcmobigpeffafkodonchffocl";
  braveManagedPolicyPlist = pkgs.writeText "com.brave.Browser.plist" (
    lib.generators.toPlist { escape = true; } {
      # Allow the signed BPC CRX to stay enabled after manual install so it can
      # use its own update manifest. Keep off-store auto-install policies out of
      # this plist; unmanaged macOS Brave has rejected those before.
      ExtensionInstallAllowlist = [ braveBpcExtensionId ];
    }
  );

  piLocalModelId = "gemma-4-e4b-heretic";
  piLocalModelPort = 8080;
  piLocalModelPath = "/Users/cjv/Models/pi/gemma-4-E4B-it-ultra-uncensored-heretic-Q8_0.gguf";
  piTrajanusModelId = "qwen3.6-27b-heretic-q4km-mtp4-100k";
  piTrajanusModelPort = 18081;
  piTrajanusModelPath = "/models/gguf/qwen3.6-27b-mtp/llmfan46/Q4_K_M/Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-Q4_K_M.gguf";
  piTrajanusMoeModelId = "qwen3.6-35b-a3b-byteshape-iq4xs-mtp2";
  piTrajanusMoeModelPort = 18082;
  piTrajanusMoeModelPath = "/models/gguf/qwen3.6-35b-a3b-mtp/byteshape/MTP-GPU-5/Qwen3.6-35B-A3B-IQ4_XS-4.19bpw.gguf";

  piLlamaE4b = pkgs.writeShellScriptBin "pi-llama-e4b" ''
    set -eu

    model_path=${lib.escapeShellArg piLocalModelPath}
    if [ ! -f "$model_path" ]; then
      printf '%s\n' \
        "Missing model: $model_path" \
        "" \
        "Copy it from pius with:" \
        "  rsync -ah --progress root@pius:/persist/models/gemma-4-e4b-ultra-heretic/llmfan46/gemma-4-E4B-it-ultra-uncensored-heretic-Q8_0.gguf /Users/cjv/Models/pi/" >&2
      exit 1
    fi

    # Gemma 4 model-card sampler defaults include temp=1.0, top_p=0.95,
    # top_k=64, and min_p=0.0. Keep min-p explicit because llama.cpp's
    # server default is nonzero. Tested 2026-04-28: --swa-full did not fix
    # Gemma 4 prompt reuse on b8770 and cost ~660 MiB extra Metal memory.
    exec ${pkgs.llama-cpp}/bin/llama-server \
      --model "$model_path" \
      --alias ${lib.escapeShellArg piLocalModelId} \
      --host 127.0.0.1 \
      --port ${toString piLocalModelPort} \
      --no-webui \
      --parallel 1 \
      --ctx-size 32768 \
      --gpu-layers auto \
      --flash-attn auto \
      --reasoning off \
      --jinja \
      --cache-type-k q8_0 \
      --cache-type-v q8_0 \
      --temp 1.0 \
      --top-p 0.95 \
      --top-k 64 \
      --min-p 0.0
  '';

  piLlamaTrajanusQwen36 = pkgs.writeShellScriptBin "pi-llama-trajanus-qwen36-27b" ''
    set -eu

    remote=trajanus
    session=pi-qwen36-27b
    model_path=${lib.escapeShellArg piTrajanusModelPath}
    model_id=${lib.escapeShellArg piTrajanusModelId}
    port=${toString piTrajanusModelPort}
    server=/models/sota-src/llama.cpp-mainline-20260519-latest/build-vulkan-rpc-ninja/bin/llama-server

    ssh "$remote" "tmux has-session -t '$session' 2>/dev/null || tmux new-session -d -s '$session' \
      '$server' \
      --model '$model_path' \
      --alias '$model_id' \
      --host 127.0.0.1 \
      --port '$port' \
      --no-webui \
      --parallel 1 \
      --ctx-size 100000 \
      --threads 4 \
      --threads-batch 4 \
      --batch-size 128 \
      --ubatch-size 128 \
      --gpu-layers 99 \
      --flash-attn on \
      --cache-type-k q4_0 \
      --cache-type-v q4_0 \
      --spec-type draft-mtp \
      --spec-draft-n-max 4 \
      --cache-type-k-draft q4_0 \
      --cache-type-v-draft q4_0 \
      --no-host \
      --poll 0 \
      --timeout 3600"

    printf 'trajanus llama-server tmux session: %s\n' "$session" >&2
    printf 'Pi model: trajanus-qwen36/%s\n' "$model_id" >&2
    printf 'Opening SSH tunnel on http://127.0.0.1:%s/v1\n' "$port" >&2
    exec ssh -N -L "127.0.0.1:$port:127.0.0.1:$port" "$remote"
  '';

  piLlamaTrajanusQwen36Stop = pkgs.writeShellScriptBin "pi-llama-trajanus-qwen36-27b-stop" ''
    set -eu

    port=${toString piTrajanusModelPort}
    ssh trajanus "tmux kill-session -t pi-qwen36-27b 2>/dev/null || true"
    pkill -f "ssh .*127.0.0.1:$port:127.0.0.1:$port.*trajanus" 2>/dev/null || true
  '';

  piLlamaTrajanusQwen36Moe = pkgs.writeShellScriptBin "pi-llama-trajanus-qwen36-35b-a3b-byteshape" ''
    set -eu

    remote=trajanus
    session=pi-qwen36-35b-a3b-byteshape
    model_path=${lib.escapeShellArg piTrajanusMoeModelPath}
    model_id=${lib.escapeShellArg piTrajanusMoeModelId}
    port=${toString piTrajanusMoeModelPort}
    server=/models/sota-src/llama.cpp-mainline-20260519-latest/build-vulkan/bin/llama-server

    ssh "$remote" "tmux has-session -t '$session' 2>/dev/null || tmux new-session -d -s '$session' \
      '$server' \
      --model '$model_path' \
      --alias '$model_id' \
      --host 127.0.0.1 \
      --port '$port' \
      --no-webui \
      --parallel 1 \
      --ctx-size 100000 \
      --threads 4 \
      --threads-batch 4 \
      --batch-size 128 \
      --ubatch-size 128 \
      --gpu-layers 99 \
      --flash-attn on \
      --cache-type-k q8_0 \
      --cache-type-v q8_0 \
      --spec-type draft-mtp \
      --spec-draft-n-max 2 \
      --cache-type-k-draft q4_0 \
      --cache-type-v-draft q4_0 \
      --no-host \
      --poll 0 \
      --timeout 3600 \
      --reasoning off \
      --reasoning-budget 0"

    printf 'trajanus llama-server tmux session: %s\n' "$session" >&2
    printf 'Pi model: trajanus-qwen36-moe/%s\n' "$model_id" >&2
    printf 'Opening SSH tunnel on http://127.0.0.1:%s/v1\n' "$port" >&2
    exec ssh -N -L "127.0.0.1:$port:127.0.0.1:$port" "$remote"
  '';

  piLlamaTrajanusQwen36MoeStop = pkgs.writeShellScriptBin "pi-llama-trajanus-qwen36-35b-a3b-byteshape-stop" ''
    set -eu

    port=${toString piTrajanusMoeModelPort}
    ssh trajanus "tmux kill-session -t pi-qwen36-35b-a3b-byteshape 2>/dev/null || true"
    pkill -f "ssh .*127.0.0.1:$port:127.0.0.1:$port.*trajanus" 2>/dev/null || true
  '';

  piIncognito = pkgs.writeShellScriptBin "pi-incognito" ''
    exec pi --no-session --no-context-files "$@"
  '';

  piTrajanusQwen36 = pkgs.writeShellScriptBin "pi-trajanus-qwen36-27b" ''
    exec pi --model ${lib.escapeShellArg "trajanus-qwen36/${piTrajanusModelId}"} "$@"
  '';

  piTrajanusQwen36Incognito = pkgs.writeShellScriptBin "pi-trajanus-qwen36-27b-incognito" ''
    exec pi \
      --no-session \
      --no-context-files \
      --model ${lib.escapeShellArg "trajanus-qwen36/${piTrajanusModelId}"} \
      "$@"
  '';

  piTrajanusQwen36Moe = pkgs.writeShellScriptBin "pi-trajanus-qwen36-35b-a3b-byteshape" ''
    exec pi --model ${lib.escapeShellArg "trajanus-qwen36-moe/${piTrajanusMoeModelId}"} "$@"
  '';

  piTrajanusQwen36MoeIncognito = pkgs.writeShellScriptBin "pi-trajanus-qwen36-35b-a3b-byteshape-incognito" ''
    exec pi \
      --no-session \
      --no-context-files \
      --model ${lib.escapeShellArg "trajanus-qwen36-moe/${piTrajanusMoeModelId}"} \
      "$@"
  '';

  codexTerminalPaletteTheme = "base16";
  codexTerminalPaletteThemeConfig = pkgs.writeShellScriptBin "codex-terminal-palette-theme" ''
    set -eu

    config_path="''${CODEX_HOME:-$HOME/.codex}/config.toml"
    mkdir -p "$(dirname "$config_path")"

    CODEX_CONFIG_PATH="$config_path" \
    CODEX_TUI_THEME=${lib.escapeShellArg codexTerminalPaletteTheme} \
      ${pkgs.python3.withPackages (pythonPackages: [ pythonPackages.tomlkit ])}/bin/python - <<'PY'
    import os
    import stat
    from pathlib import Path

    import tomlkit

    config_path = Path(os.environ["CODEX_CONFIG_PATH"])
    theme = os.environ["CODEX_TUI_THEME"]

    if config_path.exists():
        original_mode = stat.S_IMODE(config_path.stat().st_mode)
        doc = tomlkit.parse(config_path.read_text())
    else:
        original_mode = 0o600
        doc = tomlkit.document()

    tui = doc.get("tui")
    if not isinstance(tui, tomlkit.items.Table):
        tui = tomlkit.table()
        doc["tui"] = tui

    if tui.get("theme") == theme:
        raise SystemExit(0)

    tui["theme"] = theme

    tmp_path = config_path.with_name(config_path.name + ".tmp")
    tmp_path.write_text(tomlkit.dumps(doc))
    tmp_path.chmod(original_mode)
    os.replace(tmp_path, config_path)
    PY
  '';

  tailscaleMacAppCli = pkgs.writeShellScriptBin "tailscale" ''
    set -eu

    tailscale_app=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    if [ ! -x "$tailscale_app" ]; then
      printf '%s\n' "Tailscale.app is not installed at $tailscale_app" >&2
      exit 127
    fi

    exec "$tailscale_app" "$@"
  '';
in

# Bootstrapping:
# 1. Install Nix with determinate installer (install upstream Nix, not Determinate Nix)
#   curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
# 2. Use nix run to run the first rebuild
#   nix run nix-darwin -- switch --flake ~/Documents/nixos#air
# 3. Use darwin-rebuild normally
#   darwin-rebuild switch --flake ~/Documents/nixos#air

# References:
# - https://gist.github.com/jmatsushita/5c50ef14b4b96cb24ae5268dab613050
# - https://github.com/LnL7/nix-darwin
#   - https://daiderd.com/nix-darwin/manual/index.html#sec-options
{
  home-manager.backupFileExtension = "hm-backup";

  imports = [
    "${self}/profiles/darwin/darwin-file-backup.nix"
    "${self}/profiles/darwin/emacs.nix"
    "${self}/profiles/darwin/fish.nix"
  ];

  nix = {
    # Bootstrap installs Nix separately on macOS, so keep nix-darwin from
    # trying to manage the Nix installation itself here.
    enable = false;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      substituters = [ "https://cache.numtide.com" ];
      trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
    };

    registry = {
      nixpkgs.flake = inputs.nixpkgs-darwin;
      unstable.flake = inputs.nixpkgs-unstable;
    };

    extraOptions = lib.optionalString (pkgs.stdenv.hostPlatform.system == "aarch64-darwin") ''
      extra-platforms = x86_64-darwin aarch64-darwin
    '';
  };

  networking.hostName = "air";

  fonts.packages = [
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.nerd-fonts.symbols-only
    pkgs.symbola
  ];

  environment.etc = {
    "fonts/fonts.conf".source = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
    "fonts/conf.d/50-macos-fonts.conf".source = fontconfigMacosConf;
  };

  environment.systemPackages = with pkgs; [
    colima # Streamlines Docker, just run `colima start`.
    docker
    ghostty-bin
    htop
    firefox-bin
    freerdp
    llama-cpp
    nixos-rebuild
    signal-desktop
    tailscaleMacAppCli
    telegram-desktop
    vesktop-discord

    delta
    dua
    fd
    gh
    hyperfine
    ripgrep-all
    uutils-coreutils-noprefix

    piLlamaE4b
    piLlamaTrajanusQwen36
    piLlamaTrajanusQwen36Stop
    piLlamaTrajanusQwen36Moe
    piLlamaTrajanusQwen36MoeStop
    piIncognito
    piTrajanusQwen36
    piTrajanusQwen36Incognito
    piTrajanusQwen36Moe
    piTrajanusQwen36MoeIncognito
    brainworkshop

    android-tools
    fzf
    hugo
    go
    guile
    neovim
    pipxFixed
    rlwrap
    sbcl
    uv
    wget
    ffmpeg
    video-vibe-check
    whisper-cpp
    yt-dlp
    org-daily-scratch
    hermesAgent
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default

    # HM's mpv module doesn't support package = null, so reference its
    # finalPackage to land mpv.app in /Applications/Nix Apps without
    # duplicating the override from profiles/home-manager/mpv.nix.
    config.home-manager.users.cjv.programs.mpv.finalPackage
  ];

  nixpkgs = {
    config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "firefox-bin"
        "firefox-bin-unwrapped"
        "symbola"
      ];
  };

  homebrew = {
    # STATE: requires manually installing Homebrew: brew.sh
    # If not installed, nix-darwin will instruct on how to install
    enable = true;
    # Keep Homebrew on PATH declaratively instead of shelling out to
    # `brew shellenv` during Fish startup. cmux's embedded Ghostty layer can
    # currently hit a PermissionDenied opening TCC-protected cwd paths under
    # ~/Documents, which then breaks the shellenv hook and leaves Fish without
    # `brew` on PATH.
    enableFishIntegration = false;

    onActivation = {
      autoUpdate = true;
      cleanup = "uninstall";
      # Homebrew 4.7+ requires an explicit force flag for non-interactive cleanup.
      extraFlags = [ "--force-cleanup" ];
      upgrade = true;
    };

    brews = [
      "trash"
    ];

    # Update these applicatons manually.
    # As brew would update them by unninstalling and installing the newest
    # version, it could lead to data loss.
    casks = [
      "balenaetcher"
      "brave-browser"
      "claude-code@latest"
      "cmux"
      "comfyui"
      "codex"
      "feather"
      "flux-app"
      "karabiner-elements" # STATE: Rebind right-command to right-option
      "keepingyouawake" # Simple open-source menu bar wrapper around caffeinate. If I want a more custom toggle later, SwiftBar plus a small plugin is a good fallback.
      # "microsoft-office" # Only have installed when needed (has some sinister telemetry).
      "microsoft-teams" # Only have installed when needed (has some sinister telemetry).
      # "monitorcontrol" # Brightness and volume controls for external monitors.
      "orcaslicer"
      "orion"
      "stremio"
      "stillcolor"
      "syncthing-app"
      "transmission"
      "trader-workstation"
      # "tunnelblick" # OpenVPN client - re-enable if needed.
      "ukelele"
      "unnaturalscrollwheels"
      "utm"
      "whatsapp"
      "zed@preview"
      "zoom"
    ];

    masApps = {
      # STATE:
      # - Enable browser extension
      # - Match URI by host
      # - Unlock with biometrics, both in extension settings and desktop app settings
      # - Enable browser integration in desktop app settings)
      Bitwarden = 1352778147;
      #"Davinci Resolve" = 571213070;
      Tailscale = 1475387142;
      "uBlock Origin Lite" = 6745342698;
    };

    taps = [
    ];
  };

  programs.man.enable = true;

  environment.variables = {
    EDITOR = "nvim";
    GHOSTTY_RESOURCES_DIR = "${pkgs.ghostty-bin}/Applications/Ghostty.app/Contents/Resources/ghostty";
    HOMEBREW_CELLAR = "/opt/homebrew/Cellar";
    HOMEBREW_NO_ANALYTICS = "1";
    HOMEBREW_PREFIX = "/opt/homebrew";
    HOMEBREW_REPOSITORY = "/opt/homebrew";
    PI_SKIP_VERSION_CHECK = "1";
    PI_TELEMETRY = "0";
  };

  # Disable press and hold for diacritics.
  # I want to be able to press and hold j and k
  # in VSCode with vim keys to move around.
  system.defaults.NSGlobalDomain.ApplePressAndHoldEnabled = false;

  # https://tonsky.me/blog/monitors/#turn-off-font-smoothing
  # https://www.reddit.com/r/MacOS/comments/16tow2w/psa_turn_off_font_smoothing/
  system.defaults.NSGlobalDomain.AppleFontSmoothing = 1;

  system.defaults.trackpad = {
    ActuateDetents = true;
    ActuationStrength = 0;
    FirstClickThreshold = 0;
    ForceSuppressed = true;
  };

  # Keyboard
  system.keyboard.enableKeyMapping = true;
  system.keyboard.remapCapsLockToControl = true;

  security.pam.services.sudo_local.touchIdAuth = true;

  # Required by home-manager.
  users.knownUsers = [ "cjv" ];
  users.users.cjv = {
    uid = 501;
    home = "/Users/cjv";
    shell = pkgs.fish;
  };

  home-manager.users.cjv = {
    # Home Manager's generated manpage currently triggers a context warning in
    # the pinned docs builder during darwin evaluation; keep the rest of the
    # HM config and nix-darwin docs intact by disabling only that output.
    manual.manpages.enable = false;

    imports = [
      "${self}/profiles/home-manager/brave.nix"
      "${self}/profiles/home-manager/firefox-darwin.nix"
      "${self}/profiles/home-manager/helix.nix"
      "${self}/profiles/home-manager/himalaya.nix"
      "${self}/profiles/home-manager/mpv.nix"
      "${self}/profiles/home-manager/neovim.nix"
      "${self}/profiles/home-manager/ssh.nix"
    ];

    home.sessionPath = [
      # STATE: install juliaup manually with curl method
      "/Users/cjv/.juliaup/bin/"
      "/Users/cjv/.local/bin"
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"
    ];

    # Ghostty is installed via environment.systemPackages so it lands in
    # /Applications/Nix Apps. package = null avoids HM double-installing it
    # under ~/Applications/Home Manager Apps.
    programs.ghostty = {
      enable = true;
      package = null;
      settings = {
        theme = "light:Gruvbox Light,dark:Gruvbox Dark Hard";
      };
    };

    # cmux only looks in ~/.config/ghostty/themes and /Applications/Ghostty.app
    # for Ghostty themes. Expose the Nix-provided themes at the user path so
    # cmux can pick up Gruvbox and friends while Ghostty itself stays managed
    # via Nix Apps.
    home.file.".config/ghostty/themes".source =
      "${pkgs.ghostty-bin}/Applications/Ghostty.app/Contents/Resources/ghostty/themes";

    # Codex's gruvbox-* syntax themes emit fixed RGB colors and do not respond
    # to config reloads in already-open TUIs. Keep only the TUI theme key in
    # Codex's otherwise stateful config aligned with Ghostty's live Gruvbox
    # palette, while leaving auth, trusted projects, and user prefs mutable.
    home.activation.codexTerminalPaletteTheme = {
      before = [ ];
      after = [ "writeBoundary" ];
      data = ''
        $DRY_RUN_CMD ${codexTerminalPaletteThemeConfig}/bin/codex-terminal-palette-theme
      '';
    };

    # Keep the whole directory store-backed. Karabiner watches the parent
    # directory and warns against symlinking only karabiner.json.
    home.file.".config/karabiner".source = karabinerConfigDir;

    # Keep cmux's embedded browser available for deliberate use, but route
    # automatic link opening to the system browser instead of unexpectedly
    # hijacking terminal links, `open https://...`, PR links, or detected
    # localhost ports.
    home.file.".config/cmux/settings.json" = {
      force = true;
      text = builtins.toJSON {
        app = {
          sendAnonymousTelemetry = false;
        };
        browser = {
          defaultSearchEngine = "kagi";
          openTerminalLinksInCmuxBrowser = false;
          interceptTerminalOpenCommandInCmuxBrowser = false;
        };
        sidebar = {
          openPullRequestLinksInCmuxBrowser = false;
          openPortLinksInCmuxBrowser = false;
        };
      };
    };

    home.file.".pi/agent/models.json".text = builtins.toJSON {
      providers = {
        llama-cpp = {
          baseUrl = "http://localhost:${toString piLocalModelPort}/v1";
          api = "openai-completions";
          apiKey = "none";
          compat = {
            supportsDeveloperRole = false;
            supportsReasoningEffort = false;
          };
          models = [
            {
              id = piLocalModelId;
              name = "Gemma 4 E4B Heretic (local llama.cpp)";
              reasoning = false;
              input = [ "text" ];
              contextWindow = 32768;
              maxTokens = 8192;
              cost = {
                input = 0;
                output = 0;
                cacheRead = 0;
                cacheWrite = 0;
              };
            }
          ];
        };

        trajanus-qwen36 = {
          baseUrl = "http://127.0.0.1:${toString piTrajanusModelPort}/v1";
          api = "openai-completions";
          apiKey = "none";
          compat = {
            supportsDeveloperRole = false;
            supportsReasoningEffort = false;
            thinkingFormat = "qwen-chat-template";
          };
          models = [
            {
              id = piTrajanusModelId;
              name = "Qwen3.6 27B Heretic Q4_K_M MTP4 100k (trajanus)";
              reasoning = true;
              input = [ "text" ];
              contextWindow = 100000;
              maxTokens = 32768;
              cost = {
                input = 0;
                output = 0;
                cacheRead = 0;
                cacheWrite = 0;
              };
            }
          ];
        };

        trajanus-qwen36-moe = {
          baseUrl = "http://127.0.0.1:${toString piTrajanusMoeModelPort}/v1";
          api = "openai-completions";
          apiKey = "none";
          compat = {
            supportsDeveloperRole = false;
            supportsReasoningEffort = false;
            thinkingFormat = "qwen-chat-template";
          };
          models = [
            {
              id = piTrajanusMoeModelId;
              name = "Qwen3.6 35B-A3B ByteShape IQ4_XS MTP2 (trajanus)";
              reasoning = true;
              input = [ "text" ];
              contextWindow = 100000;
              maxTokens = 32768;
              cost = {
                input = 0;
                output = 0;
                cacheRead = 0;
                cacheWrite = 0;
              };
            }
          ];
        };
      };
    };

    home.file.".pi/agent/settings.json".text = builtins.toJSON {
      defaultProvider = "llama-cpp";
      defaultModel = piLocalModelId;
      defaultThinkingLevel = "off";
      enableInstallTelemetry = false;
      enabledModels = [
        piLocalModelId
        piTrajanusModelId
        piTrajanusMoeModelId
      ];
      compaction = {
        enabled = true;
        reserveTokens = 4096;
        keepRecentTokens = 12000;
      };
      retry.provider = {
        timeoutMs = 600000;
        maxRetries = 0;
      };
    };

    home.activation.karabinerConfigMigration = {
      before = [ "checkLinkTargets" ];
      after = [ ];
      data = ''
        target="$HOME/.config/karabiner"
        backup="$HOME/.config/karabiner.pre-declarative"

        if [ -e "$target" ] && [ ! -L "$target" ]; then
          if [ -e "$backup" ]; then
            echo "Refusing to replace $target because $backup already exists." >&2
            exit 1
          fi

          $DRY_RUN_CMD mv "$target" "$backup"
        fi
      '';
    };

    home.activation.karabinerReload = {
      before = [ ];
      after = [ "writeBoundary" ];
      data = ''
        if /bin/launchctl print "gui/$UID/org.pqrs.service.agent.karabiner_console_user_server" >/dev/null 2>&1; then
          $DRY_RUN_CMD /bin/launchctl kickstart -k "gui/$UID/org.pqrs.service.agent.karabiner_console_user_server"
        elif /bin/launchctl print "gui/$UID/org.pqrs.karabiner.karabiner_console_user_server" >/dev/null 2>&1; then
          $DRY_RUN_CMD /bin/launchctl kickstart -k "gui/$UID/org.pqrs.karabiner.karabiner_console_user_server"
        fi
      '';
    };

    home.activation.karabinerLegacyLaunchAgentCleanup = {
      before = [ "karabinerReload" ];
      after = [ "writeBoundary" ];
      data = ''
        legacy="$HOME/Library/LaunchAgents/org.nixos.activate_karabiner_system_ext.plist"

        if [ -e "$legacy" ]; then
          $DRY_RUN_CMD /bin/launchctl bootout "gui/$UID" "$legacy" 2>/dev/null || true
          $DRY_RUN_CMD rm -f "$legacy"
        fi
      '';
    };

    home.stateVersion = "23.05";
  };

  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -d "/opt/homebrew/share/fish/completions"
      set -p fish_complete_path "/opt/homebrew/share/fish/completions"
    end
    if test -d "/opt/homebrew/share/fish/vendor_completions.d"
      set -p fish_complete_path "/opt/homebrew/share/fish/vendor_completions.d"
    end
  '';

  # Keep post-activation cleanup targeted. Avoid mutating app bundles here:
  # patching /Applications/cmux.app breaks its code signature, which in turn
  # makes macOS more likely to forget Files & Folders consent across updates.
  # cmux can already consume Ghostty integration via the exported
  # GHOSTTY_RESOURCES_DIR environment variable above.
  system.activationScripts.postActivation.text = ''
    legacy_cmux_ghostty_si="/Applications/cmux.app/Contents/Resources/ghostty/shell-integration"
    if [ -L "$legacy_cmux_ghostty_si" ]; then
      rm -f "$legacy_cmux_ghostty_si"
    fi

    # Spotlight and LaunchServices can be unreliable with app bundles nested
    # under /Applications/Nix Apps. Expose managed root-level symlinks while
    # leaving real apps, casks, and unrelated symlinks alone.
    nix_apps_dir="/Applications/Nix Apps"
    lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    primary_user=${lib.escapeShellArg config.system.primaryUser}

    for managed_link in /Applications/*.app; do
      [ -L "$managed_link" ] || continue

      link_target=$(readlink "$managed_link")
      case "$link_target" in
        "$nix_apps_dir"/*.app)
          if [ ! -d "$nix_apps_dir" ] || [ ! -e "$link_target" ]; then
            rm -f "$managed_link"
          fi
          ;;
      esac
    done

    if [ -d "$nix_apps_dir" ]; then
      for nix_app in "$nix_apps_dir"/*.app; do
        [ -e "$nix_app" ] || continue

        app_name=$(basename "$nix_app")
        app_link="/Applications/$app_name"

        if [ -L "$app_link" ]; then
          link_target=$(readlink "$app_link")
          case "$link_target" in
            "$nix_app") ;;
            "$nix_apps_dir"/*.app) rm -f "$app_link" ;;
            *)
              echo "Skipping $app_link because it already points to $link_target" >&2
              continue
              ;;
          esac
        elif [ -e "$app_link" ]; then
          echo "Skipping $app_link because it already exists and is not a managed symlink" >&2
          continue
        fi

        if [ ! -e "$app_link" ]; then
          ln -s "$nix_app" "$app_link"
        fi
        for searchable_app in "$nix_app" "$app_link"; do
          "$lsregister" -f "$searchable_app" 2>/dev/null || true
          /usr/bin/sudo -u "$primary_user" "$lsregister" -f "$searchable_app" 2>/dev/null || true
          /usr/bin/mdimport "$searchable_app" 2>/dev/null || true
        done
      done

      /usr/bin/mdimport "$nix_apps_dir" 2>/dev/null || true
    fi

    # Karabiner 15.9 now manages its own launchd jobs via ServiceManagement.
    # Older nix-darwin jobs can linger in /Library and keep pointing at stale
    # store paths after the repo stopped declaring them.
    for legacy in \
      "/Library/LaunchDaemons/org.nixos.start_karabiner_daemons.plist" \
      "/Library/LaunchDaemons/org.nixos.setsuid_karabiner_session_monitor.plist" \
      "/Library/LaunchDaemons/org.pqrs.Karabiner-DriverKit-VirtualHIDDeviceClient.plist" \
      "/Library/LaunchDaemons/org.pqrs.karabiner.karabiner_grabber.plist" \
      "/Library/LaunchDaemons/org.pqrs.karabiner.karabiner_observer.plist"
    do
      if [ -e "$legacy" ]; then
        /bin/launchctl bootout system "$legacy" 2>/dev/null || true
        rm -f "$legacy"
      fi
    done

    # Allow Bypass Paywalls Clean's signed CRX install/update path. Brave reads
    # Chromium policies from macOS managed preferences; keep the policy narrow
    # so Rustab and Chrome Web Store extensions remain handled elsewhere.
    brave_managed_preferences="/Library/Managed Preferences"
    mkdir -p "$brave_managed_preferences"
    chown root:wheel "$brave_managed_preferences"
    chmod 755 "$brave_managed_preferences"
    install -m 0644 ${braveManagedPolicyPlist} "$brave_managed_preferences/com.brave.Browser.plist"

    # macOS configuration profiles materialize user-scoped managed preferences
    # here. Overwrite that path too, rather than removing it, so only the narrow
    # allowlist survives from earlier experiments.
    mkdir -p "$brave_managed_preferences/cjv"
    chown root:wheel "$brave_managed_preferences/cjv"
    chmod 755 "$brave_managed_preferences/cjv"
    install -m 0644 ${braveManagedPolicyPlist} "$brave_managed_preferences/cjv/com.brave.Browser.plist"
    /usr/bin/killall cfprefsd 2>/dev/null || true
  '';

  ids.gids.nixbld = 350;
  system.primaryUser = "cjv";

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
}
