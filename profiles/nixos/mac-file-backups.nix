{
  self,
  pkgs,
  ...
}:

let
  dataset = "zsafe/mac-backups";
  mountpoint = "/mnt/mac-backups";
in
{
  imports = [
    "${self}/profiles/nixos/zfs/sanoid.nix"
  ];

  services.sanoid = {
    templates.macFiles = {
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
      use_template = [ "macFiles" ];
      recursive = true;
    };
  };

  systemd.services.mac-file-backups-dataset = {
    description = "Create the ZFS dataset for plain-file Mac backups";
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
      ${pkgs.coreutils}/bin/install -d -m 0750 ${mountpoint}/mac
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${mountpoint} 0750 root root -"
  ];
}
