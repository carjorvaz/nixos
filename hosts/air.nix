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
    (basicRemap (key "right_command") (key "right_option"))
  ];

  externalKeyboardModifierPolicy =
    [
      (conditionedRemap nonBuiltInKeyboardCondition (key "caps_lock") (key "left_control"))
    ]
    ++ (swap
      (conditionedRemap nonBuiltInKeyboardCondition)
      (key "left_command")
      (key "left_option"));

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
            description = "Map right command to right option on every keyboard";
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
    "${self}/profiles/darwin/kimi-cli-update-reminder.nix"
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
    brainworkshop

    android-tools
    fzf
    hugo
    go
    guile
    pkgs.kimi-cli
    neovim
    pipx
    rlwrap
    sbcl
    uv
    wget
    yt-dlp
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default

    # HM's mpv module doesn't support package = null, so reference its
    # finalPackage to land mpv.app in /Applications/Nix Apps without
    # duplicating the override from profiles/home-manager/mpv.nix.
    config.home-manager.users.cjv.programs.mpv.finalPackage
  ];

  nixpkgs = {
    overlays = [
      (final: prev: {
        kimi-cli =
          pkgs.runCommand "kimi-cli"
            {
              nativeBuildInputs = [
                pkgs.makeWrapper
                pkgs.patch
                pkgs.ripgrep
              ];
              passthru.version = inputs.kimi-cli.packages.${final.stdenv.hostPlatform.system}.kimi-cli.version;
            }
            ''
              original=${inputs.kimi-cli.packages.${final.stdenv.hostPlatform.system}.kimi-cli}

              # Extract virtual env path from the original wrapper script.
              venvPath=$(sed -n 's|.*exec "\(/nix/store/[^"]*\)".*|\1|p' "$original/bin/kimi")
              venvPath=$(dirname "$(dirname "$venvPath")")

              # Copy the virtual env so we can patch it.
              cp -rL "$venvPath" $out
              chmod -R u+w $out

              sitePackages=
              for candidate in "$out"/lib/python*/site-packages; do
                if [ -d "$candidate" ]; then
                  sitePackages="$candidate"
                  break
                fi
              done
              [ -n "$sitePackages" ]

              patch --fuzz=0 -d "$sitePackages" -p0 < ${self}/patches/kimi-cli/infinite-approval-timeout.patch
              find "$sitePackages/kimi_cli" -type d -name __pycache__ -prune -exec rm -rf {} +

              # Recreate the wrapper around the patched virtual env.
              mv $out/bin/kimi $out/bin/.kimi-unwrapped
              makeWrapper $out/bin/.kimi-unwrapped $out/bin/kimi \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.ripgrep ]} \
                --set KIMI_CLI_NO_AUTO_UPDATE "1"
            '';
      })
    ];

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
      "Davinci Resolve" = 571213070;
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
      providers.llama-cpp = {
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
    };

    home.file.".pi/agent/settings.json".text = builtins.toJSON {
      defaultProvider = "llama-cpp";
      defaultModel = piLocalModelId;
      defaultThinkingLevel = "off";
      enableInstallTelemetry = false;
      enabledModels = [ piLocalModelId ];
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

  # Keep the remaining post-activation cleanup narrow. Avoid mutating app
  # bundles here: patching /Applications/cmux.app breaks its code signature,
  # which in turn makes macOS more likely to forget Files & Folders consent
  # across updates. cmux can already consume Ghostty integration via the
  # exported GHOSTTY_RESOURCES_DIR environment variable above. Remove the old
  # symlink if it exists so the cask can return to its vendor layout.
  system.activationScripts.postActivation.text = ''
    legacy_cmux_ghostty_si="/Applications/cmux.app/Contents/Resources/ghostty/shell-integration"
    if [ -L "$legacy_cmux_ghostty_si" ]; then
      rm -f "$legacy_cmux_ghostty_si"
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
