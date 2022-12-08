final: prev: {
  # keep sources first, this makes sources available to the pkgs
  sources = prev.callPackage (import ./_sources/generated.nix) {};

  # then, call packages with `final.callPackage`
}
