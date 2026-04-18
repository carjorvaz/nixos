{
  config,
  lib,
  pkgs,
  ...
}:

# ZFS-based impermanence that rolls root back on clean shutdown rather than at
# the next boot. This keeps rollback policy separate from the storage layout.
let
  cfgZfs = config.boot.zfs;
in
{
  systemd.shutdownRamfs.contents."/etc/systemd/system-shutdown/zpool".source = lib.mkForce (
    pkgs.writeShellScript "zpool-sync-shutdown" ''
      ${cfgZfs.package}/bin/zfs rollback -r zroot/local/root@blank
      exec ${cfgZfs.package}/bin/zpool sync
    ''
  );

  systemd.shutdownRamfs.storePaths = [ "${cfgZfs.package}/bin/zfs" ];
}
