{
  description = "A highly structured configuration database.";

  nixConfig.extra-experimental-features = "nix-command flakes";
  nixConfig.extra-substituters =
    "https://nrdxp.cachix.org https://nix-community.cachix.org";
  nixConfig.extra-trusted-public-keys =
    "nrdxp.cachix.org-1:Fc5PSqY2Jm1TrWfm88l6cvGWwz3s93c6IOifQWnhNW4= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";

  inputs = {
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    # Track channels with commits tested and built by hydra
    nixos.url = "github:nixos/nixpkgs/nixos-23.05";
    latest.url = "github:nixos/nixpkgs/nixos-unstable";

    digga.url = "github:divnix/digga";
    digga.inputs.nixpkgs.follows = "nixos";
    digga.inputs.nixlib.follows = "nixos";
    digga.inputs.home-manager.follows = "home";
    digga.inputs.deploy.follows = "deploy";

    home.url = "github:nix-community/home-manager/release-23.05";
    home.inputs.nixpkgs.follows = "nixos";

    deploy.url = "github:serokell/deploy-rs";
    deploy.inputs.nixpkgs.follows = "nixos";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixos";

    nvfetcher.url = "github:berberman/nvfetcher";
    nvfetcher.inputs.nixpkgs.follows = "nixos";

    naersk.url = "github:nmattia/naersk";
    naersk.inputs.nixpkgs.follows = "nixos";

    nixos-hardware.url = "github:nixos/nixos-hardware";

    nixos-generators.url = "github:nix-community/nixos-generators";

    impermanence.url = "github:nix-community/impermanence/master";

    simple-nixos-mailserver.url =
      "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-23.05";
  };

  outputs = { self, digga, nixos, home, nixos-hardware, nur, agenix, nvfetcher
    , deploy, impermanence, nixpkgs, ... }@inputs:
    digga.lib.mkFlake {
      inherit self inputs;

      channelsConfig = { allowUnfree = true; };

      channels = {
        nixos = {
          imports = [ (digga.lib.importOverlays ./overlays) ];
          overlays = [ ];
        };
        latest = { };
      };

      lib = import ./lib { lib = digga.lib // nixos.lib; };

      sharedOverlays = [
        (final: prev: {
          __dontExport = true;
          lib = prev.lib.extend (lfinal: lprev: { our = self.lib; });
        })

        nur.overlay
        agenix.overlays.default
        nvfetcher.overlays.default

        (import ./pkgs)
      ];

      nixos = {
        hostDefaults = {
          system = "x86_64-linux";
          channelName = "nixos";
          imports = [ (digga.lib.importExportableModules ./modules) ];
          modules = [
            { lib.our = self.lib; }
            digga.nixosModules.bootstrapIso
            digga.nixosModules.nixConfig
            home.nixosModules.home-manager
            agenix.nixosModules.age
            impermanence.nixosModule
          ];
        };

        imports = [ (digga.lib.importHosts ./hosts) ];
        hosts = { };
        importables = rec {
          profiles = digga.lib.rakeLeaves ./profiles // {
            users = digga.lib.rakeLeaves ./users;
          };
          suites = with profiles; rec {
            base = [
              core.nixos
              users.cjv
              users.root
              locale
              neovim
              ssh
              zfs.common
              zsh
            ];
            desktop = base
              ++ [ bootloader emacs fwupd graphical.common pipewire scanning ];
            laptop = desktop ++ [ iwd ];
            server = base
              ++ [ autoUpgrade fail2ban passwordlessSudo zfs.email ];
            media = [
              bazarr
              calibre
              jellyfin
              ombi
              prowlarr
              radarr
              readarr
              sonarr
              transmission
            ];

            aurelius = desktop ++ [ graphical.gnome.common libvirt ];
            commodus = desktop ++ media ++ [
              acme.common
              acme.dns-vaz-ovh
              dns.resolved
              homer
              graphical.gnome.common
              intel-hardware-transcoding
              nextcloud
              nginx.common
              nginx.commodus
              oci-containers.docker
              printing
              vpn.nebula
            ];
            hadrianus = server ++ [
              acme.common
              acme.http
              acme.dns-vaz-one
              dns.resolved
              mail
              nginx.blog
              nginx.common
              nginx.bastion
              nginx.mafalda
              vpn.nebula
            ];
          };
        };
      };

      home = {
        imports = [ (digga.lib.importExportableModules ./users/modules) ];
        modules = [ ];
        importables = rec {
          profiles = digga.lib.rakeLeaves ./users/profiles;
          suites = with profiles; rec { base = [ direnv git ]; };
        };
        users = {
          nixos = { suites, ... }: { imports = suites.base; };
        }; # digga.lib.importers.rakeLeaves ./users/hm;
      };

      devshell = ./shell;

      homeConfigurations = digga.lib.mergeAny
        (digga.lib.mkHomeConfigurations self.nixosConfigurations);

      deploy.nodes = digga.lib.mkDeployNodes self.nixosConfigurations { };
    };
}
