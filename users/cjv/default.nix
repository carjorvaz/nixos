{ ... }:

{
  users.users.cjv = {
    isNormalUser = true;
    description = "Carlos Vaz";
    extraGroups = [ "wheel" ];
  };

  home-manager.users.cjv.home.stateVersion = "22.11";
}
