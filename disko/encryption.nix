{ lib, ... }: {
  disko.devices.zpool.zroot = {
    rootFsOptions = {
      encryption = "aes-256-gcm";
      # nixos-anywhere will hang until you type the passphrase.
      keylocation = "prompt";
      keyformat = "passphrase";
    };
  };
}
