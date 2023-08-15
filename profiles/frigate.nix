{ config, lib, pkgs, ... }:

# STATE:
# - h265 (h265+ on Hikvision, Smart Codec on Dahua)
#
# Main Stream (for Recording):
# - Highest Resolution (1080p)
# - 15 FPS
# - I Frame Interval: 30
#
# Sub Stream (for Detection):
# - Currently using 720p or highest below that
#   - https://docs.frigate.video/frigate/camera_setup#choosing-a-detect-resolution
# - 5 FPS
# - I Frame Interval: 5
#
# - Static Network configuration
#   - 192.168.1.1X
#     - 192.168.1.10 - Switch
#     - 192.168.1.11 - Dahua
#     - 192.168.1.12 - Hikvision
#   - Default gateway
#   - DNS Servers: 1.1.1.1, 1.0.0.1
# - Current system doesn't support Hardware Video Acceleration
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
          # Passwords are in plain text for simplicity because the cameras are
          # inside a VLAN that can't talk to the outside world.

          Dahua = {
            ffmpeg = {
              inputs = [
                {
                  path =
                    "rtsp://admin:Unkempt-Distinct@192.168.1.11:554/cam/realmonitor?channel=1&subtype=0";
                  roles = [ "record" ];
                }
                {
                  path =
                    "rtsp://admin:Unkempt-Distinct@192.168.1.11:554/cam/realmonitor?channel=1&subtype=1";
                  roles = [ "detect" ];
                }
              ];
            };

            detect = {
              enabled = true;
              width = 704;
              height = 576;
            };

            record.enabled = true;
            snapshots.enabled = true;
          };

          Hikvision = {
            ffmpeg = {
              inputs = [
                {
                  path =
                    "rtsp://admin:Unkempt-Distinct@192.168.1.12:554/Streaming/channels/101";
                  roles = [ "record" ];
                }
                {
                  path =
                    "rtsp://admin:Unkempt-Distinct@192.168.1.12:554/Streaming/channels/102";
                  roles = [ "detect" ];
                }
              ];
            };

            detect = {
              enabled = true;
              width = 640;
              height = 480;
            };

            record.enabled = true;
            snapshots.enabled = true;
          };
        };
      };
    };
  };

  environment.persistence."/persist".directories =
    [ "/var/lib/private/frigate" ];
}
