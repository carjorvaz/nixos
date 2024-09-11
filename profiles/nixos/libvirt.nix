{
  config,
  lib,
  pkgs,
  ...
}:

{
  virtualisation = {
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };

  programs.virt-manager.enable = true;
  users.users.cjv.extraGroups = [ "libvirtd" ];

  environment.systemPackages = with pkgs; [ virtiofsd ];

  environment.persistence."/persist".directories = [ "/var/lib/libvirt" ];
}
