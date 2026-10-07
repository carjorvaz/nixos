{ lib, ... }:
{
  disko.devices.zpool.zroot.datasets."safe/home" = {
    type = "zfs_fs";
    mountpoint = "/home";
  };

  # The store moved to the spare 1 TB NVMe (`zdata/nix`) on 2026-10-05: zroot
  # had reached ~96% and `/nix` was its largest snapshot-free occupant (54.9
  # GiB, no snapshots to preserve). Keep disko from regenerating the old fstab
  # entry here; the live mount is declared in hosts/trajanus.nix against
  # `zdata/nix`. Since `/nix` is in NixOS's pathsNeededForBoot, that entry also
  # makes zdata a stage-1 root pool. The migration is complete: the old
  # `zroot/local/nix` is destroyed (zroot went 27 -> 82 GiB free). A reinstall
  # must create `zdata/nix` by hand before activation, exactly like
  # `zdata/models` — zdata is not disko-managed.
  disko.devices.zpool.zroot.datasets."local/nix".mountpoint = lib.mkForce null;
}
