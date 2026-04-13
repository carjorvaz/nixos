{
  self,
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
            "workbench.preferredDarkColorTheme" = "Gruvbox Dark Hard";
            "workbench.preferredLightColorTheme" = "Gruvbox Light Hard";

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
    nodePackages.prettier

    brainworkshop

    # STATE: Settings > Linux Settings > Disable Opening Discord at Startup and Minimizing to Tray
    (discord.override { withOpenASAR = true; }) # Disable if on aarch64
    foliate
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
