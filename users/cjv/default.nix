{ hmUsers, ... }:

{
  home-manager.users = { inherit (hmUsers) cjv; };

  users.users.cjv = {
    isNormalUser = true;
    description = "Carlos Vaz";
    extraGroups = [ "wheel" ];
  };
}
