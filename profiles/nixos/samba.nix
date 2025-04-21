{ ... }:

let
  user = "samba";
  privatePath = "/mnt/samba/private";
  tmPath = "/mnt/samba/tm_share";
in
{
  # https://wiki.nixos.org/wiki/Samba#Server_setup
  services = {
    samba = {
      enable = true;

      settings = {
        global = {
          "workgroup" = "WORKGROUP";
          "server string" = "smbnix";
          "netbios name" = "smbnix";
          "security" = "user";

          # Only available on localhost and Tailscale
          # note: localhost is the ipv6 localhost ::1
          "hosts allow" = "100.64.0.0/10 127.0.0.1 localhost";
          "hosts deny" = "0.0.0.0/0";
          "guest account" = "nobody";
          "map to guest" = "bad user";
        };

        "private" = {
          "path" = privatePath;
          "valid users" = user;
          "public" = "no";
          "writeable" = "yes";
          "force user" = user;
          "fruit:aapl" = "yes";
          "vfs objects" = "catia fruit streams_xattr";
        };

        # Connect first through Finder > Go > Connect to Server (CMD + K)
        # Tailscale MagicDNS wasn't working, so I needed to use the Tailscale IP.
        # Finally, use this as a backup disk in Time Machine Settings (prefer Encrypted Backups).
        "tm_share" = {
          "path" = tmPath;
          "valid users" = user;
          "public" = "no";
          "writeable" = "yes";
          "force user" = user;
          # Below are the most imporant for macOS compatibility
          # Change the above to suit your needs
          "fruit:aapl" = "yes";
          "fruit:time machine" = "yes";
          "vfs objects" = "catia fruit streams_xattr";
        };
      };
    };

    samba-wsdd = {
      enable = true;
      discovery = true;
    };

    avahi = {
      enable = true;

      publish.enable = true;
      publish.userServices = true;
      nssmdns4 = true;

      # https://wiki.nixos.org/wiki/Samba#Apple_Time_Machine
      extraServiceFiles = {
        timemachine = ''
          <?xml version="1.0" standalone='no'?>
          <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
          <service-group>
            <name replace-wildcards="yes">%h</name>
            <service>
              <type>_smb._tcp</type>
              <port>445</port>
            </service>
              <service>
              <type>_device-info._tcp</type>
              <port>0</port>
              <txt-record>model=TimeCapsule8,119</txt-record>
            </service>
            <service>
              <type>_adisk._tcp</type>
              <!--
                change tm_share to share name, if you changed it.
              -->
              <txt-record>dk0=adVN=tm_share,adVF=0x82</txt-record>
              <txt-record>sys=waMa=0,adVF=0x100</txt-record>
            </service>
          </service-group>
        '';
      };
    };
  };

  fileSystems."${privatePath}" = {
    device = "zsafe/samba";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."${tmPath}" = {
    device = "zsafe/timemachine";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  # Set up password: https://wiki.nixos.org/wiki/Samba#User_Authentication
  users.users.${user}.isNormalUser = true;

  # Share path must be owned by the respective unix user. (e.g. ❯ chown -R samba: /samba)
  systemd.tmpfiles.rules = [
    "d ${privatePath} 0755 ${user} users"
    "d ${tmPath} 0755 ${user} users"
  ];
}
