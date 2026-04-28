{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cjv.storage.pius.samba;
  user = "samba";
  privatePath = cfg.privatePath;
  tmPath = cfg.timeMachinePath;
  tmDataset = cfg.timeMachineDataset;
in
{
  options.cjv.storage.pius.samba = {
    privateDataset = lib.mkOption {
      type = lib.types.str;
      default = "zsafe/samba";
      description = "ZFS dataset backing the private Samba share.";
    };

    privatePath = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/samba/private";
      description = "Mountpoint and exported path for the private Samba share.";
    };

    timeMachineDataset = lib.mkOption {
      type = lib.types.str;
      default = "zsafe/timemachine";
      description = "ZFS dataset backing the Time Machine Samba share.";
    };

    timeMachinePath = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/samba/tm_share";
      description = "Mountpoint and exported path for the Time Machine Samba share.";
    };
  };

  config = {
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
            "fruit:time machine max size" = "2T";
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
      device = cfg.privateDataset;
      fsType = "zfs";
      options = [ "zfsutil" ];
    };

    fileSystems."${tmPath}" = {
      device = tmDataset;
      fsType = "zfs";
      options = [ "zfsutil" ];
    };

    # Enforce a 2TB quota on the Time Machine dataset. macOS ignores the Samba
    # fruit:time machine max size setting and uses the actual volume size.
    systemd.services.zfs-timemachine-quota = {
      description = "Enforce ZFS quota on Time Machine dataset";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.zfs}/bin/zfs set quota=2T ${tmDataset}
      '';
    };

    # Set up password: https://wiki.nixos.org/wiki/Samba#User_Authentication
    users.users.${user}.isNormalUser = true;

    # Share path must be owned by the respective unix user. (e.g. ❯ chown -R samba: /samba)
    systemd.tmpfiles.rules = [
      "d ${privatePath} 0755 ${user} users"
      "d ${tmPath} 0755 ${user} users"
      "d /var/lib/samba 0755 root root -"
      "d /var/lib/samba/lock 0755 root root -"
      "d /var/lib/samba/private 0700 root root -"
      "d /var/lib/samba/private/msg.sock 0700 root root -"
    ];

    # Samba keeps its local account database and machine identity under
    # /var/lib/samba. On impermanent hosts, losing that state breaks SMB auth
    # for existing clients until the accounts are recreated.
    environment.persistence."/persist".directories = [
      "/var/lib/samba"
    ];
  };
}
