{
  self,
  config,
  inputs,
  lib,
  options,
  pkgs,
  ...
}:

let
  # TODO automatically make every pkg in pkgs/ available everywhere
  brainworkshop = pkgs.callPackage "${self}/pkgs/brainworkshop.nix" { };
  orca-slicer-appimage = pkgs.callPackage "${self}/pkgs/orca-slicer-appimage.nix" { };
  zen-browser = pkgs.callPackage "${self}/pkgs/zen-browser.nix" { };
in
{
  # Lowest input lag, from my experienece.
  # Other options:
  # - config.boot.zfs.package.latestCompatibleLinuxPackages;
  # - pkgs.linuxPackages_zen;

  boot.kernelPackages = pkgs.linuxPackages_cachyos;
  boot.zfs.package = pkgs.zfs_cachyos;
  services.scx.enable = true;
  services.scx.scheduler = "scx_lavd";

  # Prettier boot
  boot = {
    plymouth.enable = lib.mkDefault true;
    initrd.systemd.enable = lib.mkDefault true;

    # Enable "Silent Boot"
    consoleLogLevel = 0;
    initrd.verbose = false;
    kernelParams = [
      "quiet"
      "splash"
      "boot.shell_on_fail"
      "loglevel=3"
      "rd.systemd.show_status=false"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
    ];

    # Hide the OS choice for bootloaders.
    # It's still possible to open the bootloader list by pressing any key
    # It will just not appear on screen unless a key is pressed
    loader.timeout = 0;
  };

  # Improve desktop responsiveness when updating the system.
  nix.daemonCPUSchedPolicy = "idle";

  # Enable nix-ld for standard ~Common Lisp~ and Julia development.
  programs.nix-ld = {
    enable = true;
    # libraries = options.programs.nix-ld.libraries.default ++ (with pkgs; [ openssl ]);
  };

  # Suckless software overlays
  nixpkgs.overlays = [
    (self: super: {
      dmenu = super.dmenu.overrideAttrs (oldAttrs: rec {
        patches = [ ./suckless/patches/dmenu-qalc-5.2.diff ];

        configFile = super.writeText "config.h" (builtins.readFile ./suckless/dmenu-5.3-config.h);
        postPatch = ''
          ${oldAttrs.postPatch}
          cp ${configFile} config.h'';
      });

      dwm = super.dwm.overrideAttrs (oldAttrs: rec {
        patches = [
          # Move cursor to focused window/screen
          (pkgs.fetchpatch {
            url = "https://dwm.suckless.org/patches/warp/dwm-warp-6.4.diff";
            sha256 = "sha256-8z41ld47/2WHNJi8JKQNw76umCtD01OUQKSr/fehfLw=";
          })
        ];

        configFile = super.writeText "config.h" (builtins.readFile ./suckless/dwm-6.5-config.h);
        postPatch = ''
          ${oldAttrs.postPatch}
          cp ${configFile} config.h'';
      });

      slock = super.slock.overrideAttrs (oldAttrs: rec {
        patches = [
          (pkgs.fetchpatch {
            url = "https://tools.suckless.org/slock/patches/dpms/slock-dpms-1.4.diff";
            sha256 = "sha256-hfe71OTpDbqOKhu/LY8gDMX6/c07B4sZ+mSLsbG6qtg=";
          })
        ];

        configFile = super.writeText "config.h" (builtins.readFile ./suckless/slock-1.5-config.h);
        postPatch = ''
          ${oldAttrs.postPatch}
          cp ${configFile} config.h'';
      });

      st = super.st.overrideAttrs (oldAttrs: rec {
        patches = [
          (pkgs.fetchpatch {
            url = "https://st.suckless.org/patches/anysize/st-expected-anysize-0.9.diff";
            sha256 = "sha256-q21HEZoTiVb+IIpjqYPa9idVyYlbG9RF3LD6yKW4muo=";
          })
        ];

        configFile = super.writeText "config.h" (builtins.readFile ./suckless/st-0.9.2-config.h);
        postPatch = ''
          ${oldAttrs.postPatch}
          cp ${configFile} config.h'';
      });

      # https://www.reddit.com/r/archlinux/comments/15sse7i/psa_chromium_dropped_gnomekeyring_support_use/
      # https://www.reddit.com/r/archlinux/comments/18w78i5/comment/l87j82j/
      brave = super.brave.override {
        commandLineArgs = "--password-store=libsecret";
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
  };

  fonts = {
    fontDir.enable = true;
    fontconfig.defaultFonts.monospace = [ "JetBrainsMono Nerd Font" ];
    packages = with pkgs; [ nerd-fonts.jetbrains-mono ];
  };

  services = {
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

      displayManager.gdm.autoSuspend = false;
    };
  };

  programs.chromium = {
    enable = true;
    extensions = [
      # STATE: Bypass Paywalls Clean

      # STATE: Auto-fill > Default URI match detection > Host
      "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
      "mdjildafknihdffpkfmmpnpoiajfjnjd" # Consent-O-Matic
      "eimadpbcbfnmbkopoojfekhnkhdbieeh" # Dark Reader
      "gebbhagfogifgggkldgodflihgfeippi" # Return YouTube Dislike
      "mnjggcdmjocbbbhaepdhchncahnbgone" # SponsorBlock
      "khncfooichmfjbepaaaebmommgaepoid" # Unhook
    ];
  };

  home-manager.users.cjv = {
    programs = {
      # STATE:
      # - account containers (gmail, im, uni)
      firefox = {
        enable = true;

        profiles.default = {
          isDefault = true;

          # Reference: https://discourse.nixos.org/t/firefox-extensions-with-home-manager/34108
          # Check available extensions (name usually matches the short name in the URL, in the addons store):
          # $ nix flake show "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons"
          # STATE: Requires enabling the extensions manually after first install
          extensions.packages = with inputs.firefox-addons.packages.${pkgs.system}; [
            # TODO/maybe:
            # - tridactyl?
            # - unhook?

            auto-tab-discard

            # STATE:
            # - Login
            # - Settings > Auto-fill > Match Host
            bitwarden

            # STATE:
            # Select All, Save
            # bypass-paywalls-clean # TODO temporarily commented out because it's broken
            darkreader

            # STATE:
            # - Lists:
            #   - Annoyances
            #   - AdGuard Portuguese
            ublock-origin
            return-youtube-dislikes

            #STATE:
            # - General > Add preface (for userChrome)
            # - Tabs > After closing current tab activate next tab > Disable ignore discarded tabs
            sidebery
            sponsorblock
          ];

          search = {
            force = true;
            default = "Brave Search";
            engines = {
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

            # Never remember passwords
            "signon.rememberSignons" = false;

            # Customize toolbar manually then copy from about:config to turn declarative
            "browser.uiCustomization.state" = ''
              {"placements":{"widget-overflow-fixed-list":["fxa-toolbar-menu-button"],"unified-extensions-area":["_3c078156-979c-498b-8990-85f7987dd929_-browser-action","sponsorblocker_ajay_app-browser-action","_762f9885-5a13-4abd-9c77-433dcd38b8fd_-browser-action","gdpr_cavi_au_dk-browser-action","magnolia_12_34-browser-action"],"nav-bar":["back-button","forward-button","stop-reload-button","urlbar-container","save-to-pocket-button","downloads-button","unified-extensions-button","ublock0_raymondhill_net-browser-action","_446900e4-71c2-419f-a6a7-df9c091e268b_-browser-action","addon_darkreader_org-browser-action"],"toolbar-menubar":["menubar-items"],"TabsToolbar":["firefox-view-button","tabbrowser-tabs","new-tab-button","alltabs-button"],"PersonalToolbar":["import-button","personal-bookmarks"]},"seen":["save-to-pocket-button","developer-button","_3c078156-979c-498b-8990-85f7987dd929_-browser-action","_446900e4-71c2-419f-a6a7-df9c091e268b_-browser-action","addon_darkreader_org-browser-action","sponsorblocker_ajay_app-browser-action","ublock0_raymondhill_net-browser-action","_762f9885-5a13-4abd-9c77-433dcd38b8fd_-browser-action","gdpr_cavi_au_dk-browser-action","magnolia_12_34-browser-action"],"dirtyAreaCache":["nav-bar","PersonalToolbar","unified-extensions-area","toolbar-menubar","TabsToolbar","widget-overflow-fixed-list"],"currentVersion":20,"newElementCount":3}
            '';

            # Privacy settings
            "browser.topsites.contile.enabled" = false;
            "browser.newtabpage.activity-stream.showSponsored" = false;
            "browser.newtabpage.activity-stream.system.showSponsored" = false;
            "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
            "dom.security.https_only_mode" = true;
            "privacy.trackingprotection.enabled" = true;

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

            # Enable userChrome.css
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

            # Force hardware vdeo decoding
            "media.ffmpeg.vaapi.enabled" = true;
            "media.hardware-video-decoding.force-enabled" = true;
            "gfx.webrender.all" = true;

            # Fix using KDE file picker
            # https://wiki.nixos.org/wiki/Firefox#Use_KDE_file_picker
            "widget.use-xdg-desktop-portal.file-picker" = 1;
          };

          # https://github.com/mbnuqw/sidebery/wiki/Firefox-Styles-Snippets-(via-userChrome.css)#completely-hide-native-tabs-strip
          userChrome =
            let
              preface = "[Sidebery] "; # Enable and set same preface in Sidebery settings
            in
            ''
              /**
               * Dynamic Horizontal Tabs Toolbar (with animations)
               * sidebar.verticalTabs: false (with native horizontal tabs)
               */
              #main-window #TabsToolbar > .toolbar-items {
                overflow: hidden;
                transition: height 0.3s 0.3s !important;
              }
              /* Default state: Set initial height to enable animation */
              #main-window #TabsToolbar > .toolbar-items { height: 3em !important; }
              #main-window[uidensity="touch"] #TabsToolbar > .toolbar-items { height: 3.35em !important; }
              #main-window[uidensity="compact"] #TabsToolbar > .toolbar-items { height: 2.7em !important; }
              /* Hidden state: Hide native tabs strip */
              #main-window[titlepreface*="${preface}"] #TabsToolbar > .toolbar-items { height: 0 !important; }
              /* Hidden state: Fix z-index of active pinned tabs */
              #main-window[titlepreface*="${preface}"] #tabbrowser-tabs { z-index: 0 !important; }
              /* Hidden state: Hide window buttons in tabs-toolbar */
              #main-window[titlepreface*="${preface}"] #TabsToolbar .titlebar-spacer,
              #main-window[titlepreface*="${preface}"] #TabsToolbar .titlebar-buttonbox-container {
                display: none !important;
              }
              /* [Optional] Uncomment block below to show window buttons in nav-bar (maybe, I didn't test it on non-linux-i3wm env) */
              /* #main-window[titlepreface*="${preface}"] #nav-bar > .titlebar-buttonbox-container,
              #main-window[titlepreface*="${preface}"] #nav-bar > .titlebar-buttonbox-container > .titlebar-buttonbox {
                display: flex !important;
              } */
              /* [Optional] Uncomment one of the line below if you need space near window buttons */
              /* #main-window[titlepreface*="${preface}"] #nav-bar > .titlebar-spacer[type="pre-tabs"] { display: flex !important; } */
              /* #main-window[titlepreface*="${preface}"] #nav-bar > .titlebar-spacer[type="post-tabs"] { display: flex !important; } */
            '';
        };
      };

      ghostty = {
        enable = true;
        settings = {
          font-size = 14;
          theme = "GruvboxDark";
          # window-decoration = false; # Enable for window managers
        };
      };

      vscode = {
        enable = true;

        profiles.default = {
          extensions = with pkgs.vscode-extensions; [
            asvetliakov.vscode-neovim
            github.copilot
            mkhl.direnv
            jnoortheen.nix-ide
          ];

          userSettings = {
            "github.copilot.editor.enableAutoCompletions" = true;

            "extensions.experimental.affinity" = {
              "asvetliakov.vscode-neovim" = 1;
            };

            "telemetry.enableCrashReporter" = false;
            "telemetry.enableTelemetry" = false;
            "telemetry.telemetryLevel" = "off";
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

    services = {
      nextcloud-client = {
        enable = lib.mkDefault true;
        startInBackground = true;
      };
    };
  };

  environment.shellAliases = {
    zzz = "${pkgs.systemd}/bin/systemctl sleep";
  };

  environment.systemPackages = with pkgs; [
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
    # - Vertical Tabs (keep expanded); disable expand vertical tabs panel on mouseover when collapsed; expand vertical tabs independently per window
    # - Never show bookmarks bar
    # - Adblock lists (content-filtering):
    #   - adguard portuguese
    #   - annoyances
    # - Portuguese spell check
    # - System > Memory Saver
    # - Pinned extensions:
    #   - Bitwarden
    #   - Dark Reader
    #   - Tab Counter
    # - Search Engine shortcuts (Site Search):
    #   - !hm Home Manager Options Search https://home-manager-options.extranix.com/?query=%s
    #   - !nix (Official) NixOS Wiki https://wiki.nixos.org/w/index.php?search=%s
    #   - !nixopt NixOS options https://search.nixos.org/options?query=%s
    brave # Disable if on aarch64

    # STATE: Settings > Linux Settings > Disable Opening Discord at Startup and Minimizing to Tray
    (discord.override { withOpenASAR = true; }) # Disable if on aarch64
    firefox
    foliate
    libreoffice-fresh
    librewolf
    mattermost-desktop
    metadata-cleaner
    monero-gui

    # STATE:
    # - login, skip folders configuration, add folder connection ~/org -> Org
    # - launch on system startup, use monochrome icons
    # - move removed files to trash
    # - disable show server notifications (maybe, choose accordingly)
    nextcloud-client

    ungoogled-chromium
    orca-slicer-appimage
    signal-desktop
    stremio

    # TODO: declarative with home-manager?
    # STATE:
    # - descending cards https://superuser.com/questions/13518/change-the-default-sorting-order-in-thunderbird
    # - unified folders
    # - stop the nginx systemd service when logging in to gmail  https://support.mozilla.org/en-US/questions/1373706?page=2
    # - dictionaries
    thunderbird
    zen-browser

    nautilus
    seahorse

    racket
    sbcl
    # https://www.reddit.com/r/NixOS/comments/10io6ae/comment/j5foln9/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button
    openssl
    openssl.dev
    openssl.out
    rlwrap

    python3

    kubectl
    kubernetes-helm
    unstable.talosctl

    bashmount
    glib # gsettings
    imv
    libqalculate
    mpv
    pamixer
    pavucontrol
    pulseaudio # for pactl
    pulsemixer
    skypeforlinux
    xclip
    xlayoutdisplay
    yt-dlp
    zathura
    zoom-us
  ];
}
