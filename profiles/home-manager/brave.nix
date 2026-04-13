{
  inputs,
  pkgs,
  lib,
  ...
}:

let
  rustab = inputs.rustab.packages.${pkgs.stdenv.hostPlatform.system}.default;
  rustabExtension = rustab.chromeExtension;
  rustabDarwinNativeMessagingHostDirs = [
    "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
    "Library/Application Support/Chromium/NativeMessagingHosts"
    "Library/Application Support/Google/Chrome/NativeMessagingHosts"
  ];
  rustabDarwinNativeMessagingHostDirsArgs = lib.escapeShellArgs rustabDarwinNativeMessagingHostDirs;
  rustabNativeMessagingHostManifest = pkgs.writeText "rustab_mediator.json" (builtins.toJSON {
    name = "rustab_mediator";
    description = "rustab native messaging host";
    path = "${rustab}/bin/rustab-mediator";
    type = "stdio";
    allowed_origins = [
      "chrome-extension://${inputs.rustab.lib.chromeExtensionId}/"
    ];
  });
  rustabExtensionHomePath =
    if pkgs.stdenv.isDarwin then
      "Library/Application Support/rustab/chrome-extension"
    else
      ".local/share/rustab/chrome-extension";
  rustabExtensionUpdateUrl = "https://carjorvaz.github.io/rustab/chromium/updates.xml";
  bpcExtensionUpdateUrl =
    "https://gitflic.ru/project/magnolia1234/bpc_updates/blob/raw?file=updates.xml";
in

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
# - (macOS) Brave refuses off-store auto-install on unmanaged browsers, so:
#   - Rustab must still be loaded once from brave://extensions using
#     ~/Library/Application Support/rustab/chrome-extension
#   - Bypass Paywalls Clean remains a manual install on macOS
#   - Rustab's native host manifest is installed into Chromium-family
#     fallback directories because current Brave releases do not reliably
#     discover it from the branded Brave application-support path alone
{
  home.packages = [ rustab ];

  # Expose the unpacked Rustab extension at a stable home path so the macOS
  # manual load step doesn't depend on a transient /nix/store path. Use a
  # real directory tree here rather than a symlinked top-level directory,
  # since Brave appears not to register the unpacked extension reliably from
  # a symlink target.
  home.file = lib.mkIf pkgs.stdenv.isDarwin {
    "${rustabExtensionHomePath}" = {
      source = rustabExtension;
      recursive = true;
    };
  };

  home.activation.rustabChromeExtensionPathMigration =
    lib.hm.dag.entryBefore [ "checkLinkTargets" ]
      (lib.optionalString pkgs.stdenv.isDarwin ''
        rustabExtensionPath="$HOME/${rustabExtensionHomePath}"

        # Earlier generations exposed the whole extension directory as a
        # single symlink. Migrate that layout away before link generation so
        # Home Manager can materialize a real directory tree in its place.
        if [ -L "$rustabExtensionPath" ]; then
          $DRY_RUN_CMD rm "$rustabExtensionPath"
        fi
      '');

  home.activation.rustabChromiumNativeMessagingHosts =
    lib.hm.dag.entryAfter [ "writeBoundary" ]
      (lib.optionalString pkgs.stdenv.isDarwin ''
        for rustabHostDirRel in ${rustabDarwinNativeMessagingHostDirsArgs}; do
          rustabHostDir="$HOME/$rustabHostDirRel"
          rustabHostFile="$rustabHostDir/rustab_mediator.json"

          $DRY_RUN_CMD mkdir -p "$rustabHostDir"
          $DRY_RUN_CMD rm -f "$rustabHostFile"
          $DRY_RUN_CMD install -m 0644 ${rustabNativeMessagingHostManifest} "$rustabHostFile"
        done
      '');

  programs.brave = {
    enable = true;

    # Brave on macOS comes from the Homebrew cask, so skip the nix package
    # (commandLineArgs and dictionaries are unsupported when package = null).
    package = if pkgs.stdenv.isDarwin then null else pkgs.brave;

    commandLineArgs = lib.optionals (!pkgs.stdenv.isDarwin) [
      # https://www.reddit.com/r/archlinux/comments/15sse7i/psa_chromium_dropped_gnomekeyring_support_use/
      # https://www.reddit.com/r/archlinux/comments/18w78i5/comment/l87j82j/
      "--password-store=libsecret"

      # https://github.com/basecamp/omarchy/blob/master/config/brave-flags.conf
      "--enable-features=TouchpadOverscrollHistoryNavigation"

      # Load org-dump extension for saving URLs to org-roam
      "--load-extension=${pkgs.org-dump-extension}"
    ];

    nativeMessagingHosts = lib.optionals (!pkgs.stdenv.isDarwin) [ rustab ];

    # Linux supports self-hosted external extensions declaratively via
    # External Extensions JSON. macOS only allows off-store installs in
    # enterprise-managed browsers, so keep those on the manual path there.
    extensions =
      lib.optionals (!pkgs.stdenv.isDarwin) [
        {
          id = "lkbebcjgcmobigpeffafkodonchffocl"; # Bypass Paywalls Clean
          updateUrl = bpcExtensionUpdateUrl;
        }
        {
          id = inputs.rustab.lib.chromeExtensionId;
          updateUrl = rustabExtensionUpdateUrl;
        }
      ]
      ++ [
        # STATE: Check discard exceptions in settings
        "jhnleheckmknfcgijgkadoemagpecfol" # Auto Tab Discard

        # STATE: Auto-fill > Default URI match detection > Host
        # STATE: Allow extensions in private windows
        "nngceckbapebfimnlniiiahkandclblb" # Bitwarden

        # STATE: Follow system theme
        "eimadpbcbfnmbkopoojfekhnkhdbieeh" # Dark Reader
        "cdglnehniifkbagbbombnjghhcihifij" # Kagi Search
        "gebbhagfogifgggkldgodflihgfeippi" # Return YouTube Dislike
        "mnjggcdmjocbbbhaepdhchncahnbgone" # SponsorBlock
        "cdhdichomdnlaadbndgmagohccgpejae" # Remove YouTube Suggestions
        "lmkeolibdeeglfglnncmfleojmakecjb" # YouTube No Translation
      ];
  };
}
