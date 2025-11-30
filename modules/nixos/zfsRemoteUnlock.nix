{
  config,
  lib,
  pkgs,
  ...
}:

# Reference:
#
# Unlock with:
# ssh -4 -p 2222 root@host

with lib;

let
  cfg = config.cjv.zfsRemoteUnlock;
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
    };
  };

  config = mkIf cfg.enable {
    boot = {
      plymouth.enable = false;

      kernelParams = lib.mkIf cfg.static.enable [
        "ip=${cfg.static.address}::${cfg.static.gateway}:${cfg.static.netmask}::${cfg.static.interface}:none"
      ];
      initrd.supportedFilesystems = [ "zfs" ];
      initrd.kernelModules = [ cfg.driver ];
      initrd.network = {
        enable = cfg.enable;

        ssh = {
          enable = true;
          port = cfg.port;
          hostKeys = [ "${cfg.hostKeyFile}" ];
          authorizedKeys = cfg.authorizedKeys;
        };

        postCommands = ''
          # Import all pools
          zpool import -a
          # Add the load-key command to the .profile
          echo "zfs load-key -a; killall zfs" >> /root/.profile
        '';
      };
    };
  };
}
