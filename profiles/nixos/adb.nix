{ ... }:

{
  programs.adb.enable = true;
  users.users.cjv.extraGroups = [ "adbusers" ];
}
