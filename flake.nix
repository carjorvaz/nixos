{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
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

    lanzaboote.url = "github:nix-community/lanzaboote/v1.1.0";

    firefox-addons.url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
    firefox-addons.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";

    home-manager-darwin.url = "github:nix-community/home-manager";
    home-manager-darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";

    impermanence.url = "github:nix-community/impermanence";

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      inputs.nixpkgs-stable.follows = "nixpkgs";
    };

    simple-nixos-mailserver.url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-26.05";

    cl-olx-scraper.url = "github:carjorvaz/cl-olx-scraper";
    cl-olx-scraper.inputs.nixpkgs.follows = "nixpkgs-unstable";

    cl-ultimate-tic-tac-toe.url = "github:carjorvaz/cl-ultimate-tic-tac-toe";
    cl-ultimate-tic-tac-toe.inputs.nixpkgs.follows = "nixpkgs-unstable";

    ott-rs.url = "git+ssh://git@github.com/carjorvaz/ott-rs.git";
    ott-rs.inputs.nixpkgs.follows = "nixpkgs-unstable";

    pdf-translator.url = "github:carjorvaz/pdf-translator-rs";
    pdf-translator.inputs.nixpkgs.follows = "nixpkgs-unstable";

    rustab.url = "github:carjorvaz/rustab";
    rustab.inputs.nixpkgs.follows = "nixpkgs-unstable";

    telegram-mirror-rs.url = "path:../telegram-mirror-rs";
    telegram-mirror-rs.inputs.nixpkgs.follows = "nixpkgs-unstable";

    hermes-agent.url = "github:NousResearch/hermes-agent";

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
        inputs.nixpkgs.lib.mapAttrs' (
          name: _:
          let
            packagePath = pkgsDir + "/${name}";
            packageFunction = import packagePath;
            extraArgs =
              if builtins.hasAttr "inputs" (builtins.functionArgs packageFunction) then
                { inherit inputs; }
              else
                { };
          in
          {
            name = inputs.nixpkgs.lib.removeSuffix ".nix" name;
            value = pkgs.callPackage packagePath extraArgs;
          }
        ) packageEntries;

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

      mkIkLlamaPackages =
        pkgs:
        let
          # ik_llama.cpp: upstream package.nix currently returns env = [] when
          # ROCm is disabled. mkDerivation requires env to be an attrset.
          patchedStdenv = pkgs.stdenv // {
            mkDerivation =
              fnOrAttrs:
              pkgs.stdenv.mkDerivation (
                if builtins.isFunction fnOrAttrs then
                  finalAttrs:
                  let
                    result = fnOrAttrs finalAttrs;
                  in
                  result // { env = if builtins.isList (result.env or { }) then { } else result.env; }
                else
                  fnOrAttrs // { env = if builtins.isList (fnOrAttrs.env or { }) then { } else fnOrAttrs.env; }
              );
          };

          mkIkLlama =
            {
              pname,
              useRpc ? false,
              extraCmakeFlags ? [ ],
            }:
            (pkgs.callPackage "${inputs.ik-llama}/.devops/nix/package.nix" {
              effectiveStdenv = patchedStdenv;
              inherit useRpc;
            }).overrideAttrs
              (old: {
                inherit pname;
                cmakeFlags =
                  old.cmakeFlags
                  ++ [
                    (pkgs.lib.cmakeBool "GGML_LTO" true)
                  ]
                  ++ extraCmakeFlags;
              });
        in
        {
          ik-llama = mkIkLlama { pname = "ik-llama"; };
          ik-llama-rpc = mkIkLlama {
            pname = "ik-llama-rpc";
            useRpc = true;
          };
          ik-llama-avx2 = mkIkLlama {
            pname = "ik-llama-avx2";
            extraCmakeFlags = [
              (pkgs.lib.cmakeBool "GGML_NATIVE" false)
              (pkgs.lib.cmakeBool "GGML_AVX" true)
              (pkgs.lib.cmakeBool "GGML_AVX2" true)
              (pkgs.lib.cmakeBool "GGML_FMA" true)
              (pkgs.lib.cmakeBool "GGML_F16C" true)
            ];
          };
          ik-llama-zen4 = mkIkLlama {
            pname = "ik-llama-zen4";
            extraCmakeFlags = [
              (pkgs.lib.cmakeBool "GGML_NATIVE" false)
              (pkgs.lib.cmakeBool "GGML_AVX512" true)
              (pkgs.lib.cmakeBool "GGML_AVX512_VBMI" true)
              (pkgs.lib.cmakeBool "GGML_AVX512_VNNI" true)
              (pkgs.lib.cmakeBool "GGML_AVX512_BF16" true)
            ];
          };
        };

      baseModules = [
        inputs.agenix.nixosModules.default
        inputs.disko.nixosModules.disko
        inputs.lanzaboote.nixosModules.lanzaboote
        inputs.impermanence.nixosModule
        inputs.nix-index-database.nixosModules.nix-index
        ./modules/nixos/llmTuning.nix
        {
          nixpkgs.overlays = [
            localPackagesOverlay
            inputs.llm-agents.overlays.default
          ];
          programs = {
            command-not-found.enable = false;
            nix-index-database.comma.enable = true;
          };
          system.configurationRevision = self.rev or self.dirtyRev or null;
        }
      ];

      desktopModules = [
        inputs.niri.nixosModules.niri
        inputs.nix-flatpak.nixosModules.nix-flatpak
        inputs.home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = { inherit inputs; };
          };
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
            inputs.cl-ultimate-tic-tac-toe.nixosModules.default
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
            inputs.ott-rs.nixosModules.ott-rs
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

        pius-unlock-bridge = inputs.nixpkgs.lib.nixosSystem {
          # Build the Pi 1 image from trajanus instead of trying to bootstrap
          # the whole ARMv6 system under emulation.
          system = "x86_64-linux";
          specialArgs = { inherit inputs self; };
          modules = [
            {
              nixpkgs = {
                buildPlatform = "x86_64-linux";
                hostPlatform = inputs.nixpkgs.lib.systems.examples.raspberryPi;
              };
            }
            ./hosts/pius-unlock-bridge.nix
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

        llmClusterLive = inputs.nixpkgs-unstable.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs self; };
          modules = [
            ./profiles/nixos/llm-cluster-live.nix
          ];
        };
      };

      darwinConfigurations.air = inputs.nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs self; };
        modules = [
          inputs.agenix.darwinModules.default
          inputs.home-manager-darwin.darwinModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = { inherit inputs; };
            };
            nixpkgs.overlays = [
              localPackagesOverlay
            ];
          }
          inputs.nix-index-database.darwinModules.nix-index
          { programs.nix-index-database.comma.enable = true; }
          ./hosts/air.nix
        ];
      };

      checks =
        let
          mkRepoHarnessChecks =
            system:
            let
              pkgs = import (localPackagesNixpkgs system) {
                inherit system;
                config = localPackagesNixpkgsConfig;
                overlays = [ localPackagesOverlay ];
              };
            in
            import ./checks/repository-harness.nix {
              inherit pkgs;
              lib = inputs.nixpkgs.lib;
            };
        in
        inputs.nixpkgs.lib.genAttrs [
          "aarch64-darwin"
          "x86_64-darwin"
        ] mkRepoHarnessChecks
        // {
          x86_64-linux =
            let
              system = "x86_64-linux";
              pkgs = import inputs.nixpkgs {
                inherit system;
                config = localPackagesNixpkgsConfig;
                overlays = [ localPackagesOverlay ];
              };
            in
            (import ./checks/repository-harness.nix {
              inherit pkgs;
              lib = inputs.nixpkgs.lib;
            })
            // (import ./checks/firecrawl.nix {
              inherit pkgs;
              lib = inputs.nixpkgs.lib;
            })
            // (import ./checks/hindsight.nix {
              inherit pkgs;
              lib = inputs.nixpkgs.lib;
            });
        };

      devShells =
        inputs.nixpkgs.lib.genAttrs
          [
            "aarch64-darwin"
            "x86_64-darwin"
            "x86_64-linux"
          ]
          (
            system:
            let
              pkgs = import (localPackagesNixpkgs system) {
                inherit system;
                config = localPackagesNixpkgsConfig;
                overlays = [ localPackagesOverlay ];
              };
            in
            {
              default = pkgs.mkShellNoCC {
                packages = with pkgs; [
                  deadnix
                  difftastic
                  git
                  just
                  jujutsu
                  nil
                  nixfmt
                  statix
                ];

                shellHook = ''
                  echo "nixos repo shell: run 'just --list' or './scripts/validate'"
                '';
              };
            }
          );

      packages = inputs.nixpkgs.lib.genAttrs inputs.nixpkgs.lib.systems.flakeExposed (
        system:
        let
          pkgs = import (localPackagesNixpkgs system) {
            inherit system;
            config = localPackagesNixpkgsConfig;
          };
        in
        availableLocalPackages pkgs
        // inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          llm-cluster-live-iso = self.nixosConfigurations.llmClusterLive.config.system.build.isoImage;
        }
        // inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") (mkIkLlamaPackages pkgs)
      );
    };
}
