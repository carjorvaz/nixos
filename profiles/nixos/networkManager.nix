{
  ...
}:

{
  networking = {
    wireless.enable = false;

    networkmanager = {
      enable = true;
      wifi.powersave = true;
    };
  };

  users.users.cjv.extraGroups = [ "networkmanager" ];

  home-manager.users.cjv.services.network-manager-applet.enable = true;

  environment.persistence."/persist".directories = [
    "/etc/NetworkManager/system-connections"
    "/var/lib/NetworkManager"
  ];
}
