{ config, lib, pkgs, ... }:

{
  services.emacs = let
    myEmacs = pkgs.emacs-gtk.overrideAttrs (attrs: {
      # I don't want emacs.desktop file because I only use
      # emacsclient.
      postInstall = (attrs.postInstall or "") + ''
        rm $out/share/applications/emacs.desktop
      '';
    });
  in {
    enable = true;
    defaultEditor = true;
    package = ((pkgs.emacsPackagesFor myEmacs).emacsWithPackages
      (epkgs: [ epkgs.vterm epkgs.pdf-tools ]));
  };
}