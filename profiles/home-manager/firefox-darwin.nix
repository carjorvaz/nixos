{
  inputs,
  pkgs,
  lib,
  ...
}:

let
  shared = import ./firefox-common.nix { inherit inputs pkgs lib; };

  managedProfilePath = "hm-managed";
  rustabFirefoxNativeHostManifest =
    "${shared.rustab}/lib/mozilla/native-messaging-hosts/rustab_mediator.json";
in
{
  programs.firefox = {
    enable = true;

    # Firefox.app is installed via environment.systemPackages on macOS.
    package = null;

    profiles = {
      managed = {
        id = 0;
        name = "managed";
        path = managedProfilePath;
        isDefault = true;

        # STATE:
        # - Verify Sidebery layout after first launch
        # - Verify Bypass Paywalls Clean still works as expected
        # - Decide later whether to make bookmarks declarative too
        extensions.packages =
          shared.commonExtensions
          ++ shared.macManagedExtensions
          ++ [ shared.rustab.firefoxExtension ];

        search = shared.commonSearch;

        containersForce = true;
        containers = shared.macManagedContainers;
        userChrome = shared.macManagedUserChrome;

        settings = shared.commonSettings // {
          # Declarative extensions should come up enabled in the new profile.
          "extensions.autoDisableScopes" = 0;

          # Sidebery owns the tab-sidebar experience in the managed profile.
          "sidebar.verticalTabs" = false;
        };
      };
    };
  };

  home.packages = [
    (pkgs.writeShellScriptBin "firefox-managed" ''
      exec /usr/bin/open -na "/Applications/Nix Apps/Firefox.app" --args -P managed
    '')
  ];

  home.activation.rustabFirefoxNativeMessagingHost =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rustabHostDir="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
      rustabHostFile="$rustabHostDir/rustab_mediator.json"

      $DRY_RUN_CMD mkdir -p "$rustabHostDir"
      $DRY_RUN_CMD rm -f "$rustabHostFile"
      $DRY_RUN_CMD install -m 0644 ${rustabFirefoxNativeHostManifest} "$rustabHostFile"
    '';
}
