{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    firefox-addons.url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
    firefox-addons.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-23.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    impermanence.url = "github:nix-community/impermanence/master";

    simple-nixos-mailserver.url =
      "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-23.11";
  };

  outputs = { self, ... }@inputs: {
    nixosConfigurations = {
      commodus = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs self; };
        modules = [
          inputs.agenix.nixosModules.age
          inputs.disko.nixosModules.disko
          inputs.impermanence.nixosModule
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
          }
          ./hosts/commodus.nix
          ./disko/base.nix
          ./disko/desktop.nix
          ./disko/tmpfs.nix
          { _module.args.disks = [ "/dev/nvme0n1" ]; }
        ];
      };

      hadrianus = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs self; };
        modules = [
          inputs.agenix.nixosModules.age
          inputs.disko.nixosModules.disko
          inputs.impermanence.nixosModule
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
          }
          ./hosts/hadrianus.nix
          ./disko/base.nix
          ./disko/encryption.nix
          ./disko/zfsImpermanence.nix
          { _module.args.disks = [ "/dev/sda" ]; }
        ];
      };

      t440 = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs self; };
        modules = [
          inputs.agenix.nixosModules.age
          inputs.disko.nixosModules.disko
          inputs.impermanence.nixosModule
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
          }
          ./hosts/t440.nix
          ./disko/base.nix
          ./disko/tmpfs.nix
          { _module.args.disks = [ "/dev/sda" ]; }
        ];
      };

      trajanus = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs self; };
        modules = [
          inputs.agenix.nixosModules.age
          inputs.disko.nixosModules.disko
          inputs.impermanence.nixosModule
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
          }
          ./hosts/trajanus.nix
          ./disko/base.nix
          ./disko/desktop.nix
          ./disko/encryption.nix
          ./disko/zfsImpermanence.nix
          { _module.args.disks = [ "/dev/sda" ]; }
        ];
      };
    };
  };
}
