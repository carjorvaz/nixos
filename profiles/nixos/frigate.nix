{ config, lib, pkgs, ... }:

# STATE:
# - h264 (h264+ disabled on Hikvision; Smart Codec disabled on Dahua)
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
# - Static Network configuration:
#     - 192.168.1.10 - Switch
#     - 192.168.1.11 - Dahua
#     - 192.168.1.12 - Hikvision
#   - Default gateway: 192.168.1.254
#   - DNS Servers: 1.1.1.1, 1.0.0.1

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

        record = {
          enabled = true;
          retain.days = 14;
          events.retain.default = 180;
        };

        snapshots = {
          enabled = true;
          bounding_box = true;
          retain.default = 180;
        };
      };
    };
  };

  environment.persistence."/persist".directories =
    [ "/var/lib/frigate" ];
}
