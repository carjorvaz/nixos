{ config, lib, pkgs, ... }:

{
  programs.adb.enable = true;
  users.users.cjv.extraGroups = ["adbusers"];
}
