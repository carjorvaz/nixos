{ config, lib, pkgs, ... }:

{
  systemd.services.hd-idle = {
    description = "hd-idle - spin down idle hard disks";
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.hd-idle}/bin/hd-idle";
      Restart = "always";
    };

    wantedBy = [ "multi-user.target" ];
  };
}
