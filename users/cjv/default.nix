{ ... }:

{
  users.users.cjv = {
    isNormalUser = true;
    description = "Carlos Vaz";
    extraGroups = [ "wheel" ];
  };
}
