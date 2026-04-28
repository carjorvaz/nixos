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
    "Library/Application Support/Orion/NativeMessagingHosts"
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
# - (macOS) Extension caveats:
#   - Chrome Web Store extensions are declared via External Extensions JSON
#     and then copied to real files during activation because Brave appears
#     not to honor symlinked descriptors from the Nix store
#   - Kagi Search still needs the normal Brave-side default-search setup
#   - Brave refuses off-store auto-install on unmanaged browsers, so Rustab
#     must still be loaded once from brave://extensions using
#     ~/Library/Application Support/rustab/chrome-extension
#   - Orion can install that same unpacked Chrome extension via
#     Tools > Extensions > Install from Disk
#   - Bypass Paywalls Clean uses a self-hosted CRX/update manifest; on macOS
#     air.nix allowlists the signed CRX so Brave can install and auto-update it
#   - Rustab's Chrome native host manifest is installed into Chromium-family
#     fallback directories plus Orion's application-support path
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

  # Brave on macOS appears not to load Chrome Web Store external extension
  # descriptors when Home Manager exposes them as symlinks into the Nix
  # store. Materialize those JSON files as real copies after link generation
  # so Brave can discover and install the extensions.
  home.activation.braveDarwinExternalExtensions =
    lib.hm.dag.entryAfter [ "linkGeneration" ]
      (lib.optionalString pkgs.stdenv.isDarwin ''
        braveExternalExtensionsDir="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/External Extensions"

        if [ -d "$braveExternalExtensionsDir" ]; then
          for braveExternalExtensionFile in "$braveExternalExtensionsDir"/*.json; do
            if [ ! -L "$braveExternalExtensionFile" ]; then
              continue
            fi

            braveExternalExtensionSource="$(${pkgs.coreutils}/bin/readlink "$braveExternalExtensionFile")"

            if [ -z "$braveExternalExtensionSource" ]; then
              continue
            fi

            $DRY_RUN_CMD rm -f "$braveExternalExtensionFile"
            $DRY_RUN_CMD install -m 0644 "$braveExternalExtensionSource" "$braveExternalExtensionFile"
          done
        fi
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

    # Linux supports both self-hosted and Chrome Web Store external extensions
    # directly. On macOS, BPC also stays declarative because air.nix installs a
    # matching ExtensionInstallAllowlist managed policy; Rustab's unpacked
    # extension still uses the manual path on unmanaged browsers.
    extensions =
      [
        {
          id = "lkbebcjgcmobigpeffafkodonchffocl"; # Bypass Paywalls Clean
          updateUrl = bpcExtensionUpdateUrl;
        }
      ]
      ++ lib.optionals (!pkgs.stdenv.isDarwin) [
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
