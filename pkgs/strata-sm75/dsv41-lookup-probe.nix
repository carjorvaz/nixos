# tiberius: strata-dsv41 with Strata's zero-weight lookup (suffix) drafter, built from this tree's pin.
#
# The engine already carries the DSpark drafter, but its weights are not in the live pack - and even with them a
# speculative window reads the union of its rows' experts from Optane (3.3x a token's bytes), so a weighted drafter
# cannot pay on this box.  The lookup needs no weights and costs microseconds; it is exact by construction (its drafts
# go through the same Model::verify() as the drafter's).  dsv41-lookup.patch links strata_spec into strata-dsv41,
# adds --lookup on|off|auto, --lookup-k N (default 2), --lookup-min M (default 3), and makes Model::verify()'s
# scratch (d_ints/d_specq on the head device, each layer's ring_bak/c_snap) exist without an mtp.* in the pack -
# the engine gated those on the drafter's presence, and a lookup-only verify died in the head copy from a null
# d_ints ("cudaMemcpyAsync(h_idx, d_ints + 16, ...): invalid argument").  --spec-eval measures it with no DSpark
# weights at all.  DraftPolicy gates every round, so chat falls back to plain steps while a copy does not.
#
#   nix-build /persist/nixos-deploy-0242-live/pkgs/strata-sm75/dsv41-lookup-probe.nix
#   /nix/store/.../bin/strata-dsv41 --pack /optane/dsv41/pack --max-context 32768 --dspark none \
#     --lookup on --lookup-k 2 --ids ... --n 128
#
# See dsv41-probe.nix for the shape this follows; that one also installs the dsv41 tests.
let
  flake = builtins.getFlake "/persist/nixos-deploy-0242-live";
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; };
  base = pkgs.callPackage ./. { };
in
base.overrideAttrs (old: {
  pname = "strata-dsv41-sm75-lookup";
  patches = (old.patches or [ ]) ++ [ ./dsv41-lookup.patch ];
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DSTRATA_BUILD_DSV41=ON"
  ];
  # A patch that silently failed to apply would leave a binary that ignores --lookup; fail the build instead.
  postPatch = (old.postPatch or "") + ''
    grep -q 'struct LookupOpts' src/dsv41/ds4_main.cpp || {
      echo "dsv41-lookup.patch did not add the lookup (--lookup) to ds4_main.cpp" >&2
      exit 1
    }
    grep -q 'strata-dsv41 PRIVATE strata_dsv41_kernels strata_spec' CMakeLists.txt || {
      echo "CMakeLists.txt does not link strata_spec into strata-dsv41" >&2
      exit 1
    }
    grep -q 'the verify() scratch' src/dsv41/ds4_model.cu || {
      echo "dsv41-lookup.patch did not un-gate Model::verify()'s scratch (a lookup-only verify would crash)" >&2
      exit 1
    }
    grep -q 'not the drafter' src/dsv41/ds4_model.cu || {
      echo "dsv41-lookup.patch did not un-gate the verified window's ring backup" >&2
      exit 1
    }
  '';
  installPhase = (old.installPhase or "") + ''
    for t in strata-dsv41; do
      p="$(find . -maxdepth 2 -type f -name "$t" | head -1)"
      [ -n "$p" ] && install -m755 "$p" $out/bin/
    done
  '';
})
