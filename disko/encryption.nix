{ ... }:
{
  # https://wiki.nixos.org/wiki/Full_Disk_Encryption#Perf_test
  boot.initrd.availableKernelModules = [
    "aesni_intel"
    "cryptd"
  ];

  disko.devices.zpool.zroot = {
    rootFsOptions = {
      encryption = "aes-256-gcm";
      # nixos-anywhere will hang until you type the passphrase.
      keylocation = "prompt";
      keyformat = "passphrase";
    };
  };
}
