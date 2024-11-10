{
  self,
  pkgs,
  ...
}:

{
  imports = [
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/cjv.nix"
    "${self}/profiles/nixos/locale.nix"
  ];

  networking.hostName = "trajanus";

  wsl = {
    enable = true;
    defaultUser = "cjv";

    # For Emacs
    startMenuLaunchers = true;
  };

  fonts.packages = [ pkgs.emacs-all-the-icons-fonts ];

  environment.systemPackages = with pkgs; [
    ((pkgs.emacsPackagesFor emacs29-pgtk).emacsWithPackages (epkgs: [
      epkgs.vterm
      epkgs.pdf-tools
      epkgs.org-roam
    ]))
    (ripgrep.override { withPCRE2 = true; })
    fd
    sqlite # org-roam
    nixfmt-rfc-style
    zstd
  ];

  system.stateVersion = "24.05";
}
