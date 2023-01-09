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
    nixos.url = "github:nixos/nixpkgs/nixos-22.11";
    latest.url = "github:nixos/nixpkgs/nixos-unstable";

    digga.url = "github:divnix/digga";
    digga.inputs.nixpkgs.follows = "nixos";
    digga.inputs.nixlib.follows = "nixos";
    digga.inputs.home-manager.follows = "home";
    digga.inputs.deploy.follows = "deploy";

    home.url = "github:nix-community/home-manager/release-22.11";
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
      "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-22.11";
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
        agenix.overlay
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
              resolved
              ssh
              tailscale
              zfs.common
              zsh
            ];
            desktop = base ++ [
              bootloader
              emacs
              fwupd
              graphical.common
              graphical.gnome
              pipewire
              printing
              scanning
            ];
            laptop = desktop ++ [ battery iwd ];
            server = base ++ [ fail2ban passwordlessSudo zfs.email ];
            media =
              [ bazarr jellyfin ombi prowlarr radarr sonarr transmission ];

            commodus = desktop ++ media ++ [
              acme.common
              acme.dns-vaz-ovh
              homer
              intel-hardware-transcoding
              nextcloud
              nginx.common
              nginx.commodus
              oci-containers.docker
            ];
            gallus = laptop ++ [ distributedBuilds latex rnl ];
            hadrianus = server ++ [
              acme.common
              acme.http
              acme.dns-vaz-one
              # TODO ghostMafalda; requires docker
              headscale
              mail
              nginx.blog
              nginx.common
              nginx.bastion
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
