{ config, lib, pkgs, modulesPath, self, ... }: {
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ./common.nix ];

  environment = {
    # Selection of sysadmin tools that can come in handy
    systemPackages = with pkgs; [
      dosfstools
      gptfdisk
      iputils
      usbutils
      utillinux
      steam-run-native
    ];

    shellAliases = let ifSudo = lib.mkIf config.security.sudo.enable;
    in {
      # nix
      nrb = ifSudo "sudo nixos-rebuild";

      # fix nixos-option for flake compat
      nixos-option = "nixos-option -I nixpkgs=${self}/lib/compat";

      # systemd
      ctl = "systemctl";
      stl = ifSudo "s systemctl";
      utl = "systemctl --user";
      ut = "systemctl --user start";
      un = "systemctl --user stop";
      up = ifSudo "s systemctl start";
      dn = ifSudo "s systemctl stop";
      jtl = "journalctl";
    };
  };

  nix = {
    # Improve nix store disk usage
    optimise.automatic = true;
    settings = {
      auto-optimise-store = true;
      allowed-users = [ "@wheel" ];

      # This is just a representation of the nix default
      system-features = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    };
  };

  programs.bash = {
    # Enable starship
    promptInit = ''
      eval "$(${pkgs.starship}/bin/starship init bash)"
    '';
    # Enable direnv, a tool for managing shell environments
    interactiveShellInit = ''
      eval "$(${pkgs.direnv}/bin/direnv hook bash)"
    '';
  };

  # For rage encryption, all hosts need a ssh key pair
  services.openssh = {
    enable = true;
    openFirewall = lib.mkDefault false;
  };

  # Service that makes Out of Memory Killer more effective
  services.earlyoom.enable = true;

  # Allow searching through man pages with apropos(1).
  documentation.man.generateCaches = true;

  users.mutableUsers = true; # TODO hashed passwords
}
