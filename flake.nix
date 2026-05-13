{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin.url = "github:LnL7/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";

    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    lanzaboote.url = "github:nix-community/lanzaboote/v0.4.3";

    firefox-addons.url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
    firefox-addons.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";

    impermanence.url = "github:nix-community/impermanence";

    niri.url = "github:sodiboo/niri-flake";
    niri.inputs.nixpkgs.follows = "nixpkgs-unstable";
    niri.inputs.nixpkgs-stable.follows = "nixpkgs";

    simple-nixos-mailserver.url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-25.11";

    cl-olx-scraper.url = "github:carjorvaz/cl-olx-scraper";
    cl-olx-scraper.inputs.nixpkgs.follows = "nixpkgs-unstable";

    pdf-translator.url = "github:carjorvaz/pdf-translator-rs";
    pdf-translator.inputs.nixpkgs.follows = "nixpkgs-unstable";

    rustab.url = "github:carjorvaz/rustab";
    rustab.inputs.nixpkgs.follows = "nixpkgs-unstable";

    kimi-cli.url = "github:MoonshotAI/kimi-cli";

    llm-agents.url = "github:numtide/llm-agents.nix";

    tuxedo-nixos.url = "github:sund3RRR/tuxedo-nixos";

    ik-llama.url = "github:ikawrakow/ik_llama.cpp";
  };

  outputs =
    { self, ... }@inputs:
    let
      # Auto-discover all packages in pkgs/
      pkgsDir = ./pkgs;
      packageEntries =
        let
          isPackage =
            name: type:
            (type == "directory") || (type == "regular" && inputs.nixpkgs.lib.hasSuffix ".nix" name);
        in
        inputs.nixpkgs.lib.filterAttrs isPackage (builtins.readDir pkgsDir);

      mkLocalPackages =
        pkgs:
        inputs.nixpkgs.lib.mapAttrs' (name: _: {
          name = inputs.nixpkgs.lib.removeSuffix ".nix" name;
          value = pkgs.callPackage (pkgsDir + "/${name}") { };
        }) packageEntries;

      availableLocalPackages =
        pkgs:
        inputs.nixpkgs.lib.filterAttrs (
          _: pkg: inputs.nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform pkg
        ) (mkLocalPackages pkgs);

      localPackagesNixpkgs =
        system:
        if inputs.nixpkgs.lib.hasSuffix "darwin" system then inputs.nixpkgs-darwin else inputs.nixpkgs;

      localPackagesOverlay = final: _: mkLocalPackages final;

      # Some local wrappers target redistributable frontends around upstream
      # unfree apps; allow those specific inputs when exposing flake package
      # outputs without broadening host-level package policy.
      localPackagesNixpkgsConfig = {
        allowUnfreePredicate =
          pkg:
          builtins.elem (inputs.nixpkgs.lib.getName pkg) [
            "discord"
          ];
      };

      baseModules = [
        inputs.agenix.nixosModules.default
        inputs.disko.nixosModules.disko
        inputs.lanzaboote.nixosModules.lanzaboote
        inputs.impermanence.nixosModule
        inputs.nix-index-database.nixosModules.nix-index
        {
          nixpkgs.overlays = [
            localPackagesOverlay
            inputs.llm-agents.overlays.default
          ];
          programs = {
            command-not-found.enable = false;
            nix-index-database.comma.enable = true;
          };
        }
      ];

      desktopModules = [
        inputs.niri.nixosModules.niri
        inputs.nix-flatpak.nixosModules.nix-flatpak
        inputs.home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = { inherit inputs; };
        }
      ];

      impermanenceBaseModule = ./profiles/nixos/impermanence/base.nix;
      impermanenceLoginRecordsModule = ./profiles/nixos/impermanence/login-records.nix;
      zfsBootRollbackModule = ./profiles/nixos/impermanence/rollback-zfs-boot.nix;
      zfsShutdownRollbackModule = ./profiles/nixos/impermanence/rollback-zfs-shutdown.nix;
    in
    {
      nixosConfigurations = {
        hadrianus = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs self; };
          modules = baseModules ++ [
            ./hosts/hadrianus.nix
            ./disko/base.nix
            ./disko/encryption.nix
            impermanenceBaseModule
            impermanenceLoginRecordsModule
            zfsBootRollbackModule
            { cjv.impermanence.zfsBootRollback.rootDataset = "zroot/local/root"; }
            { _module.args.disks = [ "/dev/sda" ]; }
          ];
        };

        pius = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs self; };
          modules = baseModules ++ [
            inputs.cl-olx-scraper.nixosModules.default
            inputs.pdf-translator.nixosModules.pdf-translator
            ./hosts/pius.nix
            ./disko/pius.nix
            impermanenceBaseModule
            zfsBootRollbackModule
            {
              _module.args.disks = [
                "/dev/nvme0n1"
                "/dev/sda"
                "/dev/sdb"
              ];
            }
          ];
        };

        julius = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs self; };
          modules = baseModules ++ [
            ./hosts/julius.nix
            ./disko/base.nix
            impermanenceBaseModule
            impermanenceLoginRecordsModule
            zfsShutdownRollbackModule
            { _module.args.disks = [ "/dev/nvme0n1" ]; }
          ];
        };

        trajanus = inputs.nixpkgs-unstable.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs self; };
          modules =
            baseModules
            ++ desktopModules
            ++ [
              inputs.nixos-hardware.nixosModules.tuxedo-infinitybook-pro14-gen9-amd
              inputs.tuxedo-nixos.nixosModules.default
              ./hosts/trajanus.nix
              ./disko/base.nix
              ./disko/desktop.nix
              ./disko/encryption.nix
              impermanenceBaseModule
              impermanenceLoginRecordsModule
              zfsBootRollbackModule
              { cjv.impermanence.zfsBootRollback.rootDataset = "zroot/local/root"; }
              { _module.args.disks = [ "/dev/nvme0n1" ]; }
            ];
        };
      };

      darwinConfigurations.air = inputs.nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs self; };
        modules = [
          inputs.home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; };
            nixpkgs.overlays = [
              localPackagesOverlay
            ];
          }
          inputs.nix-index-database.darwinModules.nix-index
          { programs.nix-index-database.comma.enable = true; }
          ./hosts/air.nix
        ];
      };

      packages = inputs.nixpkgs.lib.genAttrs inputs.nixpkgs.lib.systems.flakeExposed (
        system:
        availableLocalPackages (
          import (localPackagesNixpkgs system) {
            inherit system;
            config = localPackagesNixpkgsConfig;
          }
        )
      );
    };
}
