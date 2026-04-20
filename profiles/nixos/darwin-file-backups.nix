{
  self,
  lib,
  pkgs,
  ...
}:

let
  # Keep the existing dataset and mountpoint names to avoid moving live backup
  # data around on pius just for nomenclature.
  dataset = "zsafe/mac-backups";
  mountpoint = "/mnt/mac-backups";
  hosts = [ "air" ];
in
{
  imports = [
    "${self}/profiles/nixos/zfs/sanoid.nix"
  ];

  services.sanoid = {
    templates.darwinFiles = {
      frequently = 0;
      hourly = 48;
      daily = 30;
      weekly = 12;
      monthly = 24;
      yearly = 5;
      autosnap = true;
      autoprune = true;
    };

    datasets.${dataset} = {
      use_template = [ "darwinFiles" ];
      recursive = true;
    };
  };

  systemd.services.darwin-file-backups-dataset = {
    description = "Create the ZFS dataset for plain-file Darwin backups";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ! ${pkgs.zfs}/bin/zfs list -H -o name ${dataset} >/dev/null 2>&1; then
        ${pkgs.zfs}/bin/zfs create -o mountpoint=${mountpoint} ${dataset}
      fi

      ${pkgs.zfs}/bin/zfs mount ${dataset} >/dev/null 2>&1 || true
      ${lib.concatMapStringsSep "\n" (host: "${pkgs.coreutils}/bin/install -d -m 0750 ${mountpoint}/${host}") hosts}
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${mountpoint} 0750 root root -"
  ];
}
