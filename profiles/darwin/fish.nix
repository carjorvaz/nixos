{ self, pkgs, ... }:

{
  home-manager.users.cjv.imports = [
    "${self}/profiles/home-manager/shell/fish.nix"
  ];

  environment.systemPackages = with pkgs; [
    grc
  ];

  home-manager.users.cjv.programs.fish.plugins = [
    { name = "done"; src = pkgs.fishPlugins.done.src; }
    { name = "grc"; src = pkgs.fishPlugins.grc.src; }
  ];

  programs = {
    fish = {
      enable = true;

      interactiveShellInit = "set fish_greeting"; # Disable greeting
    };
  };
}
