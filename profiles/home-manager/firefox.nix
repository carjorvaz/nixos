{
  inputs,
  pkgs,
  lib,
  ...
}:

let
  shared = import ./firefox-common.nix { inherit inputs pkgs lib; };
in
{
  programs.firefox = {
    enable = true;
    package = lib.mkDefault pkgs.firefox;
    nativeMessagingHosts = [ shared.rustab ];

    profiles.default = {
      isDefault = true;

      # STATE:
      # - account containers (gmail, im, uni)
      # - Requires enabling extensions manually after first install
      # Reference: https://discourse.nixos.org/t/firefox-extensions-with-home-manager/34108
      # Check available extensions:
      # $ nix flake show "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons"
      extensions.packages =
        shared.commonExtensions
        ++ shared.linuxExtensions
        ++ [ shared.rustab.firefoxExtension ];

      bookmarks = shared.commonBookmarks;
      search = shared.commonSearch;

      settings = shared.commonSettings // shared.linuxOnlySettings // {
        # Use native vertical tabs on Linux.
        "sidebar.verticalTabs" = true;
      };

      userChrome = shared.linuxUserChrome;
    };
  };
}
