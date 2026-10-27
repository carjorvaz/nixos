let
  flake = builtins.getFlake "/persist/nixos-deploy-0242-live";
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; };
  base = pkgs.callPackage ./default.nix { };
in
base.overrideAttrs (old: {
  pname = "strata-dsv41-sm75-dax";
  version = "0.1.49.2";
  # A patch file, not a substituteInPlace: a pin bump makes `patch -p1` fail loudly instead of quietly dropping the
  # DAX window.  The engine source pin is dfa3f402 (v0.2.4.2 / engine 0.1.49.2) -- see default.nix.
  patches = (old.patches or [ ]) ++ [ ./dsv41-dax.patch ];
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DSTRATA_BUILD_DSV41=ON"
    "-DSTRATA_BUILD_TESTS=OFF"
  ];
  installPhase = (old.installPhase or "") + ''
    install -m755 "$(find . -maxdepth 2 -type f -name strata-dsv41 | head -1)" $out/bin/strata-dsv41
  '';
})
