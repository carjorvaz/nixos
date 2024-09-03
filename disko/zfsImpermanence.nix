# TODO migrate everything running with root as tmpfs to this and merge this with base.nix
{
  config,
  lib,
  pkgs,
  ...
}:

# ZFS-based impermanence but instead of rolling back on every start, roll back on safe shutdown/halt/reboot.
# Copied from: https://github.com/chaotic-cx/nyx/blob/d214d9f692140d2777f78e050b0757f577d14ed3/modules/nixos/zfs-impermanence-on-shutdown.nix

let
  cfgZfs = config.boot.zfs;
in
{
  disko.devices.zpool.zroot = {
    postCreateHook = "zfs snapshot zroot/local/root@blank";
    datasets."local/root" = {
      type = "zfs_fs";
      mountpoint = "/";
    };
  };

  systemd.shutdownRamfs.contents."/etc/systemd/system-shutdown/zpool".source = lib.mkForce (
    pkgs.writeShellScript "zpool-sync-shutdown" ''
      ${cfgZfs.package}/bin/zfs rollback -r zroot/local/root@blank
      exec ${cfgZfs.package}/bin/zpool sync
    ''
  );

  systemd.shutdownRamfs.storePaths = [ "${cfgZfs.package}/bin/zfs" ];
}
