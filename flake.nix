{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    firefox-addons.url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
    firefox-addons.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-24.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    home-manager-unstable.url = "github:nix-community/home-manager";
    home-manager-unstable.inputs.nixpkgs.follows = "nixpkgs";

    impermanence.url = "github:nix-community/impermanence/master";

    simple-nixos-mailserver.url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-24.05";
  };

  outputs =
    { self, ... }@inputs:
    {
      nixosConfigurations =
        let
          baseModules = [
            inputs.agenix.nixosModules.default
            inputs.disko.nixosModules.disko
            inputs.impermanence.nixosModule
            inputs.nix-index-database.nixosModules.nix-index
            {
              programs = {
                command-not-found.enable = false;
                nix-index-database.comma.enable = true;
              };
            }
          ];

          desktopModules = [
            inputs.home-manager-unstable.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
            }
          ];
        in
        {
          aurelius = inputs.nixpkgs-unstable.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit inputs self;
            };
            modules =
              baseModules
              ++ desktopModules
              ++ [
                ./hosts/aurelius.nix
                ./disko/base.nix
                ./disko/desktop.nix
                ./disko/encryption.nix
                ./disko/zfsImpermanence.nix
                { _module.args.disks = [ "/dev/nvme0n1" ]; }
              ];
          };

          commodus = inputs.nixpkgs-unstable.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit inputs self;
            };
            modules =
              baseModules
              ++ desktopModules
              ++ [
                ./hosts/commodus.nix
                ./disko/base.nix
                ./disko/desktop.nix
                ./disko/tmpfs.nix
                { _module.args.disks = [ "/dev/nvme0n1" ]; }
              ];
          };

          hadrianus = inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit inputs self;
            };
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
            specialArgs = {
              inherit inputs self;
            };
            modules = baseModules ++ [ ./hosts/nerva.nix ];
          };

          pius = inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit inputs self;
            };
            modules = baseModules ++ [
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

          t440 = inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit inputs self;
            };
            modules = baseModules ++ [
              ./hosts/t440.nix
              ./disko/base.nix
              ./disko/tmpfs.nix
              { _module.args.disks = [ "/dev/sda" ]; }
            ];
          };

          trajanus = inputs.nixpkgs-unstable.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit inputs self;
            };
            modules =
              baseModules
              ++ desktopModules
              ++ [
                ./hosts/trajanus.nix
                ./disko/base.nix
                ./disko/desktop.nix
                ./disko/encryption.nix
                ./disko/zfsImpermanence.nix
                { _module.args.disks = [ "/dev/nvme0n1" ]; }
              ];
          };

          trajanus-wsl = inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit inputs self;
            };
            modules = baseModules ++ [
              inputs.nixos-wsl.nixosModules.default
              inputs.home-manager.nixosModules.home-manager
              {
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
              }
              ./hosts/trajanus-wsl.nix
            ];
          };
        };
    };
}
