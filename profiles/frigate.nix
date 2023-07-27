{ config, lib, pkgs, ... }:

let domain = "frigate.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
    };

    frigate = {
      enable = true;
      hostname = domain;
      settings = {
        cameras = {
          # dahua = {};
          hikvision = {
            ffmpeg.inputs = [{
              path = "rtsp://192.168.1.64/rtsp";
              roles = [
                "detect" # "rtmp"
              ];
            }];

            detect = {
              enabled = false;
              width = 1280;
              height = 720;
            };
          };
        };
      };
    };
  };

  environment.persistence."/persist".directories = [
    # "/var/lib/frigate"

    # TODO confirmar
    # "/media/frigate/clips"
    # "/media/frigate/recordings"
    # "/media/frigate/frigate.db"
    # "/tmp/cache"
    # "/dev/shm"
    # "/config/config.yml"
  ];
}
