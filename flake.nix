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

    ott-monitor.url = "git+ssh://git@github.com/carjorvaz/ott-monitor";
    ott-monitor.inputs.nixpkgs.follows = "nixpkgs-unstable";

    pdf-translator.url = "github:carjorvaz/pdf-translator-rs";
    pdf-translator.inputs.nixpkgs.follows = "nixpkgs-unstable";

    rustab.url = "github:carjorvaz/rustab";
    rustab.inputs.nixpkgs.follows = "nixpkgs-unstable";

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
          isPackage = name: type:
            (type == "directory") || (type == "regular" && inputs.nixpkgs.lib.hasSuffix ".nix" name);
        in
        inputs.nixpkgs.lib.filterAttrs isPackage (builtins.readDir pkgsDir);

      mkLocalPackages = pkgs:
        inputs.nixpkgs.lib.mapAttrs' (name: _: {
          name = inputs.nixpkgs.lib.removeSuffix ".nix" name;
          value = pkgs.callPackage (pkgsDir + "/${name}") { };
        }) packageEntries;

      localPackagesOverlay = final: _: mkLocalPackages final;

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
            ./disko/zfsImpermanence.nix
            { _module.args.disks = [ "/dev/sda" ]; }
          ];
        };

        nerva = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs self; };
          modules = baseModules ++ [
            ./hosts/nerva.nix
          ];
        };

        pius = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs self; };
          modules = baseModules ++ [
            inputs.cl-olx-scraper.nixosModules.default
            inputs.ott-monitor.nixosModules.default
            inputs.pdf-translator.nixosModules.pdf-translator
            ./hosts/pius.nix
            ./disko/pius.nix
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
            ./disko/zfsImpermanence.nix
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
              ./disko/zfsImpermanence.nix
              { _module.args.disks = [ "/dev/nvme0n1" ]; }
            ];
        };
      };

      darwinConfigurations."mac" = inputs.nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs self; };
        modules = [
          inputs.home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; };
            nixpkgs.overlays = [ inputs.llm-agents.overlays.default ];
          }
          inputs.nix-index-database.darwinModules.nix-index
          { programs.nix-index-database.comma.enable = true; }
          ./hosts/mac.nix
        ];
      };

      packages =
        let
          linuxSystems = inputs.nixpkgs.lib.filter
            (inputs.nixpkgs.lib.hasSuffix "-linux")
            inputs.nixpkgs.lib.systems.flakeExposed;
        in
        inputs.nixpkgs.lib.genAttrs linuxSystems (system:
          mkLocalPackages (import inputs.nixpkgs { inherit system; })
        );
    };
}
