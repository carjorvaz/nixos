{
  inputs,
  pkgs,
  lib,
}:

let
  rustab = inputs.rustab.packages.${pkgs.stdenv.hostPlatform.system}.default;
  firefoxAddons = inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  inherit rustab firefoxAddons;

  commonSettings = {
    # Disable Firefox View pinned tab
    "browser.tabs.firefox-view" = false;

    # Set new tab page as a blank page
    "browser.startup.homepage" = "about:blank";
    "browser.newtabpage.enabled" = false;

    # Disable all autofill - passwords, addresses, credit cards (use Bitwarden)
    "signon.rememberSignons" = false;
    "signon.autofillForms" = false;
    "extensions.formautofill.addresses.enabled" = false;
    "extensions.formautofill.creditCards.enabled" = false;

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

    # Tailscale owns DNS across hosts; keep Firefox on the system resolver.

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
    "toolkit.telemetry.server" = "data:,";
    "toolkit.telemetry.archive.enabled" = false;
    "toolkit.telemetry.newProfilePing.enabled" = false;
    "toolkit.telemetry.shutdownPingSender.enabled" = false;
    "toolkit.telemetry.updatePing.enabled" = false;
    "toolkit.telemetry.bhrPing.enabled" = false;
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

    # Follow system dark/light theme
    "layout.css.prefers-color-scheme.content-override" = 2;
  };

  linuxOnlySettings = lib.optionalAttrs pkgs.stdenv.isLinux {
    # Force hardware video decoding
    "media.ffmpeg.vaapi.enabled" = true;
    "media.hardware-video-decoding.force-enabled" = true;
    "gfx.webrender.all" = true;

    # Fix using KDE file picker
    # https://wiki.nixos.org/wiki/Firefox#Use_KDE_file_picker
    "widget.use-xdg-desktop-portal.file-picker" = 1;
  };

  commonBookmarks = {
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

  commonSearch = {
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

  commonExtensions =
    with firefoxAddons;
    [
      auto-tab-discard
      bitwarden
      kagi-search
      ublock-origin
      return-youtube-dislikes
      sponsorblock
      remove-youtube-s-suggestions
      youtube-no-translation
    ];

  linuxExtensions =
    with firefoxAddons;
    [
      vimium-c
    ];

  macManagedExtensions =
    with firefoxAddons;
    [
      sidebery
      multi-account-containers
      bypass-paywalls-clean
    ];

  linuxUserChrome = ''
    /* Compact native vertical tabs */
    sidebar-main:has(> #vertical-tabs) > #vertical-tabs {
      --tab-min-height: 22px;
      --tab-block-margin: 1px;
      --border-radius-medium: 4px;
      --tab-inner-inline-margin: 2px;
    }
  '';

  macManagedUserChrome = ''
    /**
     * Sidebery-driven Firefox chrome tweaks.
     * Based on Sidebery's README userChrome example, adapted to show
     * window buttons in the nav bar when the Sidebery sidebar is active.
     */
    #sidebar-panel-header {
      display: none !important;
    }

    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #TabsToolbar > * {
      display: none !important;
    }

    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #nav-bar {
      border-color: transparent !important;
    }

    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #sidebar-main,
    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #sidebar-launcher-splitter {
      display: none !important;
    }

    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #sidebar-box {
      padding: 0 !important;
    }

    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #sidebar-box #sidebar {
      box-shadow: none !important;
      border: none !important;
      outline: none !important;
      border-radius: 0 !important;
    }

    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #sidebar-splitter {
      --splitter-width: 3px !important;
      min-width: var(--splitter-width) !important;
      width: var(--splitter-width) !important;
      padding: 0 !important;
      margin: 0 calc(-1 * var(--splitter-width) + 1px) 0 0 !important;
      border: 0 !important;
      opacity: 0 !important;
    }

    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #sidebar-header {
      display: none !important;
    }

    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #nav-bar > .titlebar-buttonbox-container,
    #main-window:has(#sidebar-box[sidebarcommand="_3c078156-979c-498b-8990-85f7987dd929_-sidebar-action"][checked="true"]) #nav-bar > .titlebar-buttonbox-container > .titlebar-buttonbox {
      display: flex !important;
    }
  '';

  macManagedContainers = {
    Gmail = {
      id = 6;
      color = "yellow";
      icon = "circle";
    };
  };
}
