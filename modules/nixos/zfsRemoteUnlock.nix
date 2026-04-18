{
  config,
  lib,
  pkgs,
  ...
}:

# Reference:
#
# Direct unlock:
#   ssh -4 -p 2222 root@host
#
# Tor unlock:
#   torify ssh root@<onion>.onion

with lib;

let
  cfg = config.cjv.zfsRemoteUnlock;
  useSystemdInitrd = config.boot.initrd.systemd.enable;
  systemdAskPasswordAgent = "${config.boot.initrd.systemd.package}/bin/systemd-tty-ask-password-agent";
  systemdInitrdShell = pkgs.writeShellScript "initrd-zfs-remote-unlock" ''
    ${systemdAskPasswordAgent} --watch
    status=$?

    if [ "$status" -eq 0 ]; then
      printf '\nUnlock accepted, continuing boot...\n'
      sleep 1
    fi

    exit "$status"
  '';
in
{
  options = {
    cjv.zfsRemoteUnlock = {
      enable = mkEnableOption (lib.mdDoc "Encrypted ZFS pool remote unlock");

      port = mkOption {
        type = types.port;
        default = 2222;
        description = lib.mdDoc ''
          To prevent SSH clients from freaking out because a different host key is used,
          a different port for ssh is useful (assuming the same host has also a regular sshd running).
        '';
      };

      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = lib.mdDoc ''
          List of authorized SSH keys for remote unlock.
        '';
      };

      hostKeyFile = mkOption {
        type = types.path;
        default = null;
        description = lib.mdDoc ''
          Path to the SSH host keys to be used in the initrd.
          Generate key with: ssh-keygen -t ed25519 -N "" -f /path/to/ssh_host_ed25519_key
        '';
      };

      driver = mkOption {
        type = types.str;
        default = null;
        description = lib.mdDoc ''
          The network driver kernel module so that the initrd has networking.
          Checking the output of `lspci -v` on a running system may be helpful.
        '';
      };

      static = {
        enable = mkEnableOption (lib.mdDoc "Static IP configuration");

        address = mkOption {
          type = types.str;
          default = "";
          description = lib.mdDoc "The static IPv4 address to be used.";
        };

        gateway = mkOption {
          type = types.str;
          default = "";
          description = lib.mdDoc "The gateway IPv4 address to be used.";
        };

        netmask = mkOption {
          type = types.str;
          default = "";
          description = lib.mdDoc "The network mask to be used.";
        };

        interface = mkOption {
          type = types.str;
          default = "";
          description = lib.mdDoc "The network interface device to be used.";
        };
      };

      tor = {
        enable = mkEnableOption (lib.mdDoc "Tor hidden service for remote unlock");

        onionServiceDir = mkOption {
          type = types.path;
          description = lib.mdDoc ''
            Path to directory containing Tor onion service keys:
            - hostname
            - hs_ed25519_public_key
            - hs_ed25519_secret_key

            Generate with: nix-shell -p mkp224o --run "mkp224o -n 1 -d ./onion unlock"
            (use a vanity prefix like "unlock" or generate random with empty filter)
          '';
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(useSystemdInitrd && cfg.tor.enable);
        message = "cjv.zfsRemoteUnlock.tor is not yet supported with boot.initrd.systemd.enable";
      }
      {
        assertion = !(useSystemdInitrd && config.boot.zfs.requestEncryptionCredentials == false);
        message = ''
          cjv.zfsRemoteUnlock with systemd initrd expects boot.zfs.requestEncryptionCredentials
          to stay enabled so the initrd SSH session can answer the pending ZFS password prompt.
        '';
      }
    ];

    boot = {
      plymouth.enable = false;

      kernelParams = lib.mkIf cfg.static.enable [
        "ip=${cfg.static.address}::${cfg.static.gateway}:${cfg.static.netmask}::${cfg.static.interface}:none"
      ];
      initrd.supportedFilesystems = [ "zfs" ];
      initrd.kernelModules = [ cfg.driver ];

      # Include Tor in initrd when enabled
      initrd.extraUtilsCommands = mkIf (cfg.tor.enable && !useSystemdInitrd) ''
        copy_bin_and_libs ${pkgs.tor}/bin/tor
      '';

      # Copy onion service keys to initrd
      initrd.secrets = mkIf (cfg.tor.enable && !useSystemdInitrd) {
        "/etc/tor/onion/bootup" = cfg.tor.onionServiceDir;
      };

      initrd.network = {
        enable = cfg.enable;

        ssh = {
          enable = true;
          # When using Tor, SSH listens on localhost only
          port = if cfg.tor.enable then 22 else cfg.port;
          hostKeys = [ "${cfg.hostKeyFile}" ];
          authorizedKeys = cfg.authorizedKeys;
        };

        postCommands = mkIf (!useSystemdInitrd) ''
          # Import all pools
          zpool import -a

          ${optionalString cfg.tor.enable ''
            # Create Tor configuration
            cat > /etc/tor/torrc << EOF
          DataDirectory /etc/tor
          SOCKSPort 0
          HiddenServiceDir /etc/tor/onion/bootup
          HiddenServicePort 22 127.0.0.1:22
          EOF

            # Fix permissions on onion service directory
            chmod 700 /etc/tor/onion/bootup

            # Start Tor in background
            echo "Starting Tor hidden service..."
            tor -f /etc/tor/torrc &

            # Wait for Tor to bootstrap (check for hostname file being readable)
            for i in $(seq 1 60); do
              if [ -f /etc/tor/onion/bootup/hostname ]; then
                echo "Tor hidden service ready: $(cat /etc/tor/onion/bootup/hostname)"
                break
              fi
              sleep 1
            done
          ''}

          # Add the load-key command to the .profile
          echo "zfs load-key -a; killall zfs" >> /root/.profile
        '';
      };

      initrd.systemd.extraBin.initrd-zfs-remote-unlock = mkIf useSystemdInitrd systemdInitrdShell;
      initrd.systemd.users.root.shell = mkIf useSystemdInitrd "/bin/initrd-zfs-remote-unlock";
    };
  };
}
