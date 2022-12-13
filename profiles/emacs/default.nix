{ config, lib, pkgs, ... }:

{
  services.emacs = {
    enable = true;
    package = ((pkgs.emacsPackagesFor pkgs.emacs-gtk).emacsWithPackages
      (epkgs: [ epkgs.vterm epkgs.pdf-tools ]));
  };

  environment.systemPackages = with pkgs; [
    hugo # ox-hugo
    sqlite # org-roam
    nixfmt
  ];
}
