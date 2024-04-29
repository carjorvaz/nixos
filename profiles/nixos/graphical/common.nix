{ self, config, inputs, lib, pkgs, ... }:

let
  # TODO automatically make every pkg in pkgs/ available everywhere
  brainworkshop = pkgs.callPackage "${self}/pkgs/brainworkshop.nix" { };
  orca-slicer = pkgs.callPackage "${self}/pkgs/orca-slicer.nix" { };
  qidi-slicer = pkgs.callPackage "${self}/pkgs/qidi-slicer.nix" { };
in {
  # boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  # boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.kernelPackages =
    lib.mkDefault config.boot.zfs.package.latestCompatibleLinuxPackages;
  # pkgs.linuxPackages_xanmod_latest; # Lowest input lag, from my experienece.

  # Improve desktop responsiveness when updating the system.
  nix.daemonCPUSchedPolicy = "idle";

  # Pipewire
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services = {
    dbus.enable = true;

    gnome.gnome-keyring.enable = true;

    xserver = {
      enable = true;

      autoRepeatInterval = 30;
      autoRepeatDelay = 200;

      xkb = {
        layout = "us";
        options = "ctrl:nocaps compose:prsc";
        variant = "altgr-intl";
      };

      libinput = {
        enable = true;

        # Disable mouse acceleration.
        mouse.accelProfile = "flat";

        touchpad = {
          disableWhileTyping = true;
          naturalScrolling = true;
        };
      };
    };
  };

  programs.chromium = {
    enable = true;
    extensions = [
      # STATE: Bypass Paywalls Clean

      # STATE: Auto-fill > Default URI match detection > Host
      "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
      "fhnegjjodccfaliddboelcleikbmapik" # Chrome Tab Counter
      "mdjildafknihdffpkfmmpnpoiajfjnjd" # Consent-O-Matic
      "eimadpbcbfnmbkopoojfekhnkhdbieeh" # Dark Reader
      "dmhgdnbkjkejeddddlklojinngaideac" # Nudgeware
      "gebbhagfogifgggkldgodflihgfeippi" # Return YouTube Dislike
      "mnjggcdmjocbbbhaepdhchncahnbgone" # SponsorBlock
    ];
  };

  home-manager.users.cjv = {
    # TODO: disable telemetry
    # STATE:
    # - account containers (gmail, im, uni)
    programs.firefox = {
      enable = true;

      profiles.default = {
        isDefault = true;

        # Reference: https://discourse.nixos.org/t/firefox-extensions-with-home-manager/34108
        # Check available extensions (name usually matches the short name in the URL, in the addons store):
        # $ nix flake show "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons"
        # STATE: Requires enabling the extensions manually after first install
        extensions = with inputs.firefox-addons.packages.${pkgs.system}; [
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
          consent-o-matic
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
          tabliss
        ];

        search = {
          force = true;
          default = "Brave Search";
          engines = {
            "Brave Search" = {
              urls = [{
                template = "https://search.brave.com/search?q={searchTerms}";
              }];
              iconUpdateURL =
                "https://cdn.search.brave.com/serp/v2/_app/immutable/assets/favicon-32x32.B2iBzfXZ.png";
              updateInterval = 24 * 60 * 60 * 1000;
            };

            "Google".metaData.hidden = true;
          };
        };

        # Check what settings were modified in about:config > Show only modified preferences
        settings = {
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
        };

        # https://github.com/mbnuqw/sidebery/wiki/Firefox-Styles-Snippets-(via-userChrome.css)#completely-hide-native-tabs-strip
        userChrome = let
          preface =
            "[Sidebery] "; # Enable and set same preface in Sidebery settings
        in ''
          #main-window #titlebar {
            overflow: hidden;
            transition: height 0.3s 0.3s !important;
          }
          /* Default state: Set initial height to enable animation */
          #main-window #titlebar { height: 3em !important; }
          #main-window[uidensity="touch"] #titlebar { height: 3.35em !important; }
          #main-window[uidensity="compact"] #titlebar { height: 2.7em !important; }
          /* Hidden state: Hide native tabs strip */
          #main-window[titlepreface*="${preface}"] #titlebar { height: 0 !important; }
          /* Hidden state: Fix z-index of active pinned tabs */
          #main-window[titlepreface*="${preface}"] #tabbrowser-tabs { z-index: 0 !important; }
        '';
      };

    };

    # Reference: https://github.com/Misterio77/nix-config/blob/main/home/misterio/features/desktop/common/firefox.nix
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "application/pdf" = [ "firefox.desktop" ];
        "text/html" = [ "firefox.desktop" ];
        "text/xml" = [ "firefox.desktop" ];
        "x-scheme-handler/http" = [ "firefox.desktop" ];
        "x-scheme-handler/https" = [ "firefox.desktop" ];
      };
    };
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
    # - Vertical Tabs (keep expanded); disable expand vertical tabs panel on mouseover when collapsed
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
    brave # Disable if on aarch64

    # STATE: Settings > Linux Settings > Disable Opening Discord at Startup and Minimizing to Tray
    (discord.override { withOpenASAR = true; }) # Disable if on aarch64
    webcord # Cleaner and available in aarch64
    firefox
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

    nyxt
    ungoogled-chromium
    orca-slicer
    qidi-slicer
    signal-desktop
    stremio

    # TODO: declarative with home-manager?
    # STATE:
    # - descending cards https://superuser.com/questions/13518/change-the-default-sorting-order-in-thunderbird
    # - unified folders
    # - stop the nginx systemd service when logging in to gmail  https://support.mozilla.org/en-US/questions/1373706?page=2
    # - dictionaries
    betterbird

    coq # TODO delete after LP
    sbcl
    rlwrap
    python3
    yt-dlp
  ];

  home-manager.users.cjv = {
    dconf = {
      enable = true;
      settings = {
        "org/gnome/desktop/interface" = { color-scheme = "prefer-dark"; };
      };
    };

    gtk = {
      enable = true;

      theme = {
        # Use `dconf watch /` to see the correct name
        package = pkgs.adw-gtk3;
        name = "adw-gtk3-dark";
      };

      iconTheme = {
        package = pkgs.gnome.adwaita-icon-theme;
        name = "Adwaita";
      };
    };

    qt = {
      enable = true;
      platformTheme = "gnome";
      style = {
        name = "adwaita-dark";
        package = pkgs.adwaita-qt;
      };
    };
  };
}
