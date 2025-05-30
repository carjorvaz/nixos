{ ... }:

{
  imports = [ ./common.nix ];

  home-manager.users.cjv = {
    programs.fish.enable = true;
  };
}
