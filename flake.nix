{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin.url = "github:LnL7/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/0.1";

    nixos-cosmic.url = "github:lilyinstarlight/nixos-cosmic";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    chaotic.inputs.nixpkgs.follows = "nixpkgs-unstable";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    firefox-addons.url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
    firefox-addons.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-25.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    home-manager-unstable.url = "github:nix-community/home-manager";
    home-manager-unstable.inputs.nixpkgs.follows = "nixpkgs";

    impermanence.url = "github:nix-community/impermanence/master";

    simple-nixos-mailserver.url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-25.05";
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
            inputs.chaotic.nixosModules.default
            inputs.home-manager-unstable.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
            }
            inputs.nixos-cosmic.nixosModules.default
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
        };

      darwinConfigurations."mac" = inputs.nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs self; };
        modules = [
          inputs.home-manager-unstable.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
          }
          inputs.nix-index-database.darwinModules.nix-index
          { programs.nix-index-database.comma.enable = true; }
          ./hosts/mac.nix
        ];
      };
    };
}
