{
  self,
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./performance.nix
    ./quiet-boot.nix
  ];

  # Enable nix-ld for standard ~Common Lisp~ and Julia development.
  programs.nix-ld.enable = true;

  nixpkgs.overlays = [
    (self: super: {
      vscodium = super.vscodium.override {
        commandLineArgs = "--password-store=gnome-libsecret";
      };
    })
  ];

  # Pipewire
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;

    # RNNoise: neural noise suppression for the internal mic.
    # Creates a virtual "Noise Canceling source" — select it in pavucontrol
    # or per-app to route audio through the denoiser.
    extraConfig.pipewire."99-input-denoising" = {
      "context.modules" = [{
        name = "libpipewire-module-filter-chain";
        args = {
          "node.description" = "Noise Canceling source";
          "media.name" = "Noise Canceling source";
          "filter.graph" = {
            nodes = [{
              type = "ladspa";
              name = "rnnoise";
              plugin = "${pkgs.rnnoise-plugin}/lib/ladspa/librnnoise_ladspa.so";
              label = "noise_suppressor_mono";
              control = { "VAD Threshold (%)" = 50.0; };
            }];
          };
          "audio.rate" = 48000;
          "capture.props" = {
            "node.name" = "capture.rnnoise_source";
            "node.passive" = true;
            "audio.rate" = 48000;
          };
          "playback.props" = {
            "node.name" = "rnnoise_source";
            "media.class" = "Audio/Source";
            "audio.rate" = 48000;
          };
        };
      }];
    };
  };

  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
    ];

    fontDir.enable = true;
    fontconfig.defaultFonts.monospace = [ "JetBrainsMono Nerd Font" ];
    fontconfig.subpixel.rgba = "rgb";
  };

  security.pam.loginLimits = [
    {
      domain = "@users";
      item = "rtprio";
      type = "-";
      value = 1;
    }
  ];

  services = {
    displayManager.gdm.autoSuspend = false;

    libinput = {
      # Disable mouse acceleration.
      mouse.accelProfile = "flat";

      touchpad = {
        disableWhileTyping = true;
        naturalScrolling = true;
      };
    };

    xserver = {
      enable = true;

      autoRepeatInterval = 30;
      autoRepeatDelay = 300;

      xkb = {
        layout = "us";
        options = "ctrl:nocaps,compose:prsc";
        variant = "altgr-intl";
      };

      desktopManager.wallpaper.mode = "fill";
    };

    flatpak = {
      enable = true;
      # Keep false for autenticacao.gov
      uninstallUnmanaged = false;
      update.onActivation = true;
      packages = [
        # Find package names from URL, e.g.: https://flathub.org/en/apps/eu.betterbird.Betterbird

        # STATE:
        # - default sort unthreaded by descending date in all existing folders
        # - unified folders
        # - stop the nginx systemd service when logging in to gmail  https://support.mozilla.org/en-US/questions/1373706?page=2
        # - dictionaries (download and enable)
        # - disable thunderbird spam detection, move junk to junk folder
        # - message preview on the right (Alt > View > Layout)
        # - calendar
        # - card view
        "eu.betterbird.Betterbird"
      ];
    };
  };

  programs = {
    localsend.enable = true;

    nh = {
      enable = true;
      flake = "/home/cjv/Documents/nixos";
    };
  };

  home-manager.users.cjv = {
    imports = [
      "${self}/profiles/home-manager/brave.nix"
      "${self}/profiles/home-manager/btop.nix"
      "${self}/profiles/home-manager/firefox.nix"
      "${self}/profiles/home-manager/helix.nix"
      "${self}/profiles/home-manager/mpv.nix"
      "${self}/profiles/home-manager/ssh.nix"
    ];

    xdg.configFile = {
      "opencode/opencode.json".text = builtins.toJSON {
        autoupdate = false;
        share = "disabled";
        theme = config.graphical.theme.appNames.opencode;
        permission = {
          bash = "ask";
          edit = "ask";
          webfetch = "allow";
        };
        compaction = {
          auto = true;
          prune = true;
        };
        provider.local-qwen = {
          npm = "@ai-sdk/openai-compatible";
          name = "Qwen3 Coder (pius)";
          options = {
            baseURL = "https://llm.vaz.ovh/v1";
            apiKey = "not-needed";
          };
          models."qwen3-coder-30b-a3b" = {
            name = "Qwen3 Coder 30B A3B";
            limit.context = 131072;
            limit.output = 16384;
          };
        };
        model = "local-qwen/qwen3-coder-30b-a3b";
        small_model = "local-qwen/qwen3-coder-30b-a3b";
      };

      "opencode/tui.json".text = builtins.toJSON {
        "$schema" = "https://opencode.ai/tui.json";
        theme = config.graphical.theme.appNames.opencode;
      };

      "opencode/commands/commit.md".text = ''
        ---
        description: Create a git commit with a meaningful message
        ---
        Analyze the current changes and create a git commit:

        1. Run `git status` and `git diff` (staged + unstaged) to understand all changes
        2. Run `git log --oneline -5` to match the repo's commit message style
        3. Stage relevant files individually (avoid `git add -A` to prevent committing secrets)
        4. Draft a concise commit message that explains the **why**, not just the **what**
        5. Create the commit. Use a heredoc for the message: `git commit -m "$(cat <<'EOF' ... EOF)"`
        6. Do NOT push to remote unless explicitly asked
        7. Do NOT commit files that may contain secrets (.env, credentials, API keys)
      '';

      "opencode/commands/pr.md".text = ''
        ---
        description: Create a GitHub pull request
        ---
        Create a pull request for the current branch:

        1. Run `git status`, `git log`, and `git diff main...HEAD` to understand all changes
        2. Check if the branch is pushed to remote; push with `-u` if needed
        3. Draft a short PR title (under 70 chars) and a body with:
           - `## Summary` - 1-3 bullet points
           - `## Test plan` - checklist of testing steps
        4. Create the PR with `gh pr create`
        5. Return the PR URL
      '';
    };

    programs = {
      ghostty = {
        enable = true;
        settings = {
          working-directory = "home";
        };
      };

      git = {
        enable = true;
        # Reference: https://github.com/basecamp/omarchy/blob/master/config/git/config
        settings = {
          init.defaultBranch = "master";
          pull.rebase = true; # Rebase (instead of merge) on pull
          push.autoSetupRemote = true; # Automatically set upstream branch on push
          commit.verbose = true; # Include diff comment in commit message template
          column.ui = "auto"; # Output in columns when possible
          branch.sort = "-committerdate"; # Sort branches by most recent commit first
          tag.sort = "-version:refname"; # Sort version numbers as you would expect

          diff = {
            algorithm = "histogram"; # Clearer diffs on moved/edited lines
            colorMoved = "plain"; # Highlight moved blocks in diffs
            mnemonicPrefix = true; # More intuitive refs in diff output
          };

          rerere = {
            enabled = true; # Record and reuse conflict resolutions
            autoupdate = true; # Apply stored conflict resolutions automatically
          };
        };
      };

      neovim = {
        enable = true;
        extraConfig = ''
          set clipboard+=unnamedplus
        '';
      };

      vscode = {
        enable = true;
        package = pkgs.vscodium;

        profiles.default = {
          # STATE: Install anthropic.claude-code manually via Extensions UI
          # (VSCode Marketplace updates break Nix hash pinning)
          extensions = with pkgs.vscode-extensions; [
            asvetliakov.vscode-neovim
            james-yu.latex-workshop
            jdinhlife.gruvbox
            jnoortheen.nix-ide
            julialang.language-julia
            mkhl.direnv
            rooveterinaryinc.roo-cline
            tecosaur.latex-utilities
            valentjn.vscode-ltex
          ];

          userSettings = {
            "extensions.experimental.affinity" = {
              "asvetliakov.vscode-neovim" = 1;
            };

            "telemetry.enableCrashReporter" = false;
            "telemetry.enableTelemetry" = false;
            "telemetry.telemetryLevel" = "off";

            "window.autoDetectColorScheme" = true;
            "workbench.preferredDarkColorTheme" = config.graphical.theme.appNames.vscodeDark;
            "workbench.preferredLightColorTheme" = config.graphical.theme.appNames.vscodeLight;

            "terminal.integrated.commandsToSkipShell" = [
              "language-julia.interrupt"
            ];
            "julia.symbolCacheDownload" = true;
            "julia.executablePath" = "/run/current-system/sw/bin/julia";

            "roo-cline.allowedCommands" = [
              "git log"
              "git diff"
              "git show"
            ];
            "roo-cline.deniedCommands" = [ ];

            "claudeCode.preferredLocation" = "panel";
          };
        };
      };

      zathura = {
        enable = true;
        options = {
          "selection-clipboard" = "clipboard";
        };
      };
    };

    services.darkman = {
      enable = true;
      settings = {
        lat = 38.7;
        lng = -9.14;
      };

      darkModeScripts = {
        gtk-theme = ''
          ${pkgs.dconf}/bin/dconf write \
              /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
        '';
      };

      lightModeScripts = {
        gtk-theme = ''
          ${pkgs.dconf}/bin/dconf write \
              /org/gnome/desktop/interface/color-scheme "'prefer-light'"
        '';
      };
    };

    xdg.desktopEntries.smarttube = {
      name = "Send to SmartTube";
      exec = "${lib.getExe pkgs.smarttube-cli} %u";
      type = "Application";
      mimeType = [ "x-scheme-handler/smarttube" ];
      noDisplay = true;
    };

    xdg.desktopEntries.tv-cast = {
      name = "Cast to TV";
      exec = "${lib.getExe pkgs.${config.graphical.defaultTerminal}} -e ${lib.getExe pkgs.tv-cast} %u";
      type = "Application";
      mimeType = [ "x-scheme-handler/tv" ];
      noDisplay = true;
    };

    xdg.desktopEntries.org-dump = {
      name = "Dump to Org";
      exec = "${lib.getExe pkgs.org-dump-cli} %u";
      type = "Application";
      mimeType = [ "x-scheme-handler/org-dump" ];
      noDisplay = true;
    };
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "x-scheme-handler/smarttube" = [ "smarttube.desktop" ];
        "x-scheme-handler/tv" = [ "tv-cast.desktop" ];
        "x-scheme-handler/org-dump" = [ "org-dump.desktop" ];
      };
    };
  };

  environment.shellAliases = {
    zzz = "${pkgs.systemd}/bin/systemctl sleep";
  };

  environment.systemPackages = with pkgs; [
    # Helix dependencies
    helix
    basedpyright
    ruff
    prettier

    brainworkshop

    # STATE: Settings > Linux Settings > Disable Opening Discord at Startup and Minimizing to Tray
    (discord.override { withOpenASAR = true; }) # Disable if on aarch64
    foliate
    ib-tws
    libreoffice-fresh
    mattermost-desktop
    metadata-cleaner
    monero-gui

    mullvad-browser
    ungoogled-chromium
    orca-slicer
    signal-desktop
    telegram-desktop

    nautilus
    seahorse

    racket
    sbcl
    # https://www.reddit.com/r/NixOS/comments/10io6ae/comment/j5foln9/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button
    openssl
    openssl.dev
    openssl.out
    rlwrap

    aider-chat-full
    llm-agents.claude-code
    llm-agents.codex
    llm-agents.opencode
    python3

    android-tools
    smarttube-cli
    tv-cast
    org-dump-cli
    bashmount
    glib # gsettings
    imv
    libqalculate
    mpv
    pamixer
    pavucontrol
    pulseaudio # for pactl
    pulsemixer
    xclip
    yt-dlp
    zathura
  ];

  environment.persistence."/persist".directories = [ "/var/lib/flatpak" ];
}
