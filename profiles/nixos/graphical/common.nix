{
  self,
  config,
  inputs,
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
      brave = super.brave.override {
        commandLineArgs =
          # https://www.reddit.com/r/archlinux/comments/15sse7i/psa_chromium_dropped_gnomekeyring_support_use/
          # https://www.reddit.com/r/archlinux/comments/18w78i5/comment/l87j82j/
          "--password-store=libsecret"

          # https://github.com/basecamp/omarchy/blob/master/config/brave-flags.conf
          + " --enable-features=TouchpadOverscrollHistoryNavigation"

          # Load org-dump extension for saving URLs to org-roam
          + " --load-extension=${self.org-dump-extension}";
      };

      # Install native messaging host manifests so brotab works with
      # programs.firefox.nativeMessagingHosts and Brave's home.file.
      # (mirrors tridactyl-native pattern in nixpkgs)
      brotab = super.brotab.overrideAttrs (old: {
        # Enable transport timeout so the mediator self-terminates when the
        # native messaging pipe to the browser extension dies, instead of
        # hanging forever and holding the port.
        postPatch = (old.postPatch or "") + ''
          substituteInPlace brotab/mediator/brotab_mediator.py \
            --replace-fail \
              'transport = default_transport()' \
              'transport = transport_with_timeout(sys.stdin.buffer, sys.stdout.buffer, DEFAULT_TRANSPORT_TIMEOUT)'
        '';

        postFixup = (old.postFixup or "") + ''
          install -Dm444 $out/lib/python*/site-packages/brotab/mediator/firefox_mediator.json \
            $out/lib/mozilla/native-messaging-hosts/brotab_mediator.json
          substituteInPlace $out/lib/mozilla/native-messaging-hosts/brotab_mediator.json \
            --replace-fail '$PWD/brotab_mediator.py' "$out/bin/bt_mediator"

          install -Dm444 $out/lib/python*/site-packages/brotab/mediator/chromium_mediator.json \
            $out/etc/chromium/native-messaging-hosts/brotab_mediator.json
          substituteInPlace $out/etc/chromium/native-messaging-hosts/brotab_mediator.json \
            --replace-fail '$PWD/brotab_mediator.py' "$out/bin/bt_mediator"
        '';
      });

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
    chromium = {
      enable = true;
      extensions = [
        # STATE: Bypass Paywalls Clean

        # STATE: Check discard exceptions in settings
        "jhnleheckmknfcgijgkadoemagpecfol" # Auto Tab Discard

        # STATE: Auto-fill > Default URI match detection > Host
        # STATE: Allow extensions in private windows
        "nngceckbapebfimnlniiiahkandclblb" # Bitwarden

        #STATE: Follow system theme
        "eimadpbcbfnmbkopoojfekhnkhdbieeh" # Dark Reader
        "cdglnehniifkbagbbombnjghhcihifij" # Kagi Search
        "gebbhagfogifgggkldgodflihgfeippi" # Return YouTube Dislike
        "mnjggcdmjocbbbhaepdhchncahnbgone" # SponsorBlock
        "cdhdichomdnlaadbndgmagohccgpejae" # Remove YouTube Suggestions
        "lmkeolibdeeglfglnncmfleojmakecjb" # YouTube No Translation
        "mhpeahbikehnfkfnmopaigggliclhmnc" # BroTab
      ];
    };

    localsend.enable = true;

    nh = {
      enable = true;
      flake = "/home/cjv/Documents/nixos";
    };
  };

  home-manager.users.cjv = {
    imports = [
      "${self}/profiles/home-manager/btop.nix"
      "${self}/profiles/home-manager/helix.nix"
      "${self}/profiles/home-manager/mpv.nix"
      "${self}/profiles/home-manager/ssh.nix"
    ];

    programs = {
      # STATE:
      # - account containers (gmail, im, uni)
      firefox = {
        enable = true;
        nativeMessagingHosts = [ pkgs.brotab ];

        profiles.default = {
          isDefault = true;

          # Reference: https://discourse.nixos.org/t/firefox-extensions-with-home-manager/34108
          # Check available extensions (name usually matches the short name in the URL, in the addons store):
          # $ nix flake show "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons"
          # STATE: Requires enabling the extensions manually after first install
          extensions.packages =
            with inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system};
            [
              # STATE:
              # - Enable basically all exceptions in preferences
              auto-tab-discard

              # STATE:
              # - Login
              # - Settings > Auto-fill > Match Host
              bitwarden

              # STATE:
              # - Log in
              kagi-search

              # STATE:
              # - Lists:
              #   - Annoyances
              #   - AdGuard Portuguese
              ublock-origin
              return-youtube-dislikes
              sponsorblock

              # STATE:
              # - disable auto play
              # - disable show sidebar button
              # - enable show button in homepage
              # - disable scroll in fullscreen
              # - hide left sidebar
              remove-youtube-s-suggestions
              youtube-no-translation

              # STATE:
              # - Custom key mappings: map J nextTab, map K previousTab
              # - Exclusion rules: https://www.youtube.com/*
              vimium-c
              brotab
            ];

          # Accessible via hamburger menu → Bookmarks, or Ctrl+B
          bookmarks = {
            force = true;
            settings = [
              {
                name = "Send to SmartTube";
                keyword = "st";
                url = "javascript:(function(){var a=document.createElement('a');a.href='smarttube://'+encodeURIComponent(location.href);a.click()})()";
              }
              {
                name = "Dump to Org";
                keyword = "org";
                url = "javascript:(function(){var a=document.createElement('a');a.href='org-dump://'+encodeURIComponent('%s')+'?url='+encodeURIComponent(location.href);a.click()})()";
              }
            ];
          };

          search = {
            force = true;
            default = "Kagi";
            engines = {
              "Kagi" = {
                urls = [ { template = "https://kagi.com/search?q={searchTerms}"; } ];
              };

              "Brave Search" = {
                urls = [ { template = "https://search.brave.com/search?q={searchTerms}"; } ];
              };

              "Nix Options" = {
                definedAliases = [ "!nixopt" ];
                urls = [ { template = "https://search.nixos.org/options?query={searchTerms}"; } ];
              };

              "Nix Wiki" = {
                definedAliases = [ "!nix" ];
                urls = [ { template = "https://wiki.nixos.org/w/index.php?search={searchTerms}"; } ];
              };

              "Home Manager - Options Search" = {
                definedAliases = [ "!hm" ];
                urls = [ { template = "https://home-manager-options.extranix.com/?query={searchTerms}"; } ];
              };
            };
          };

          # Check what settings were modified in about:config > Show only modified preferences
          settings = {
            # Disable Firefox View pinned tab
            "browser.tabs.firefox-view" = false;

            # Set new tab page as a blank page
            "browser.startup.homepage" = "about:blank";
            "browser.newtabpage.enabled" = false;

            # Disable all autofill — passwords, addresses, credit cards (use Bitwarden)
            "signon.rememberSignons" = false;
            "signon.autofillForms" = false;
            "extensions.formautofill.addresses.enabled" = false;
            "extensions.formautofill.creditCards.enabled" = false;

            # To make toolbar layout declarative: customize toolbar manually,
            # then copy browser.uiCustomization.state from about:config here.

            # Privacy settings
            "browser.topsites.contile.enabled" = false;
            "browser.newtabpage.activity-stream.showSponsored" = false;
            "browser.newtabpage.activity-stream.system.showSponsored" = false;
            "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
            "dom.security.https_only_mode" = true;
            "privacy.trackingprotection.enabled" = true;
            "browser.contentblocking.category" = "strict";
            "privacy.globalprivacycontrol.enabled" = true;
            "privacy.globalprivacycontrol.functionality.enabled" = true;

            # Disable search suggestions
            "browser.search.suggest.enabled" = false;
            "browser.urlbar.suggest.searches" = false;

            # WebRTC: only expose default route IP (prevents VPN leak)
            "media.peerconnection.ice.default_address_only" = true;

            # Trim cross-origin referrers to scheme+host+port
            "network.http.referer.XOriginTrimmingPolicy" = 2;

            # DNS over HTTPS via Quad9
            "network.trr.mode" = 2; # TRR first, fall back to system DNS
            "network.trr.uri" = "https://dns.quad9.net/dns-query";
            "network.trr.bootstrapAddress" = "9.9.9.9";

            # Disable Normandy/Shield remote experiments
            "app.normandy.enabled" = false;
            "app.shield.optoutstudies.enabled" = false;

            # Disable crash reporter and beacon tracking
            "browser.tabs.crashReporting.sendReport" = false;
            "breakpad.reportURL" = "";
            "beacon.enabled" = false;

            # Disable Safe Browsing download hash upload (keeps local list checks)
            "browser.safebrowsing.downloads.remote.enabled" = false;

            # Anti-phishing: show punycode for internationalized domains
            "network.IDN_show_punycode" = true;

            # Disable fingerprinting vectors
            "dom.battery.enabled" = false;

            # Disable OCSP phone-home to certificate authorities (CRLite handles revocation locally)
            "security.OCSP.enabled" = 0;

            # Block media autoplay (click to play)
            "media.autoplay.default" = 5;

            # Disable JavaScript in the built-in PDF viewer
            "pdfjs.enableScripting" = false;

            # Disable captive portal and connectivity checks (Mozilla server pings)
            "network.captive-portal-service.enabled" = false;
            "network.connectivity-service.enabled" = false;

            # Disable Telemetry
            "datareporting.healthreport.uploadEnabled" = false;
            "datareporting.policy.dataSubmissionEnabled" = false;
            "dom.private-attribution.submission.enabled" = false;
            "toolkit.telemetry.unified" = false;
            "toolkit.telemetry.enabled" = false;
            "toolkit.telemetry.server" = "data:,"; # Disables telemetry server
            "toolkit.telemetry.archive.enabled" = false;
            "toolkit.telemetry.newProfilePing.enabled" = false;
            "toolkit.telemetry.shutdownPingSender.enabled" = false;
            "toolkit.telemetry.updatePing.enabled" = false;
            "toolkit.telemetry.bhrPing.enabled" = false; # Background hang reporter
            "toolkit.telemetry.firstShutdownPing.enabled" = false;

            # Never translate Portuguese
            "browser.translations.neverTranslateLanguages" = "pt";

            # Disable Pocket
            "extensions.pocket.enabled" = false;

            # Disable about:config warning
            "browser.aboutConfig.showWarning" = false;

            # Restore previous session
            "browser.startup.page" = 3;

            # Never show bookmarks bar
            "browser.toolbars.bookmarks.visibility" = "never";

            # Force hardware video decoding
            "media.ffmpeg.vaapi.enabled" = true;
            "media.hardware-video-decoding.force-enabled" = true;
            "gfx.webrender.all" = true;

            # Native vertical tabs
            "sidebar.verticalTabs" = true;

            # Enable userChrome.css
            "toolkit.legacyUserProfileCustomization.stylesheets" = true;

            # Follow system dark/light theme (works with darkman)
            "layout.css.prefers-color-scheme.content-override" = 2;

            # Fix using KDE file picker
            # https://wiki.nixos.org/wiki/Firefox#Use_KDE_file_picker
            "widget.use-xdg-desktop-portal.file-picker" = 1;
          };

          userChrome = ''
            /* Compact native vertical tabs */
            sidebar-main:has(> #vertical-tabs) > #vertical-tabs {
              --tab-min-height: 22px;
              --tab-block-margin: 1px;
              --border-radius-medium: 4px;
              --tab-inner-inline-margin: 2px;
            }


          '';
        };
      };

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

    home.file.".config/BraveSoftware/Brave-Browser/NativeMessagingHosts/brotab_mediator.json".source =
      "${pkgs.brotab}/etc/chromium/native-messaging-hosts/brotab_mediator.json";

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

    # STATE:
    # - Set as default browser
    # - Hide brave rewards icon in search bar
    # - Hide brave wallet icon
    # - Password Manager > Settings > Disable offer to save passwords
    # - Homepage:
    #   - Disable cards
    #   - Disable sponsored background images
    #   - Disable Brave News
    #   - 24 hour clock
    #   - Hide top sites
    # - Never translate Portuguese
    # - (Trajanus) Settings > 110% page zoom
    # - Vertical Tabs:
    #   - keep expanded
    #   - disable expand vertical tabs panel on mouseover when collapsed
    #   - expand vertical tabs independently per window
    # - Never show bookmarks bar
    # - Adblock lists (content-filtering):
    #   - adguard portuguese
    #   - annoyances
    #   - bypass paywalls clean
    #   - adguard url tracking protection
    # - Portuguese spell check
    # - System > Disable Memory Saver (because we have Auto Tab Discard)
    # - Pinned extensions:
    #   - Bitwarden
    # - Allow extensions in private windows
    # - Search Engine shortcuts (Site Search):
    #   - !hm Home Manager Options Search https://home-manager-options.extranix.com/?query=%s
    #   - !nix (Official) NixOS Wiki https://wiki.nixos.org/w/index.php?search=%s
    #   - !nixopt NixOS options https://search.nixos.org/options?query=%s
    # - Set up Kagi as default search engine
    #   - First enable index other search engines
    #   - https://github.com/kagisearch/chrome_extension_basic?tab=readme-ov-file#setting-default-search-on-linux
    brave # Disable if on aarch64

    # STATE: Settings > Linux Settings > Disable Opening Discord at Startup and Minimizing to Tray
    (discord.override { withOpenASAR = true; }) # Disable if on aarch64
    firefox
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

    brotab
  ];

  environment.persistence."/persist".directories = [ "/var/lib/flatpak" ];
}
