{ ... }: {
  disko.devices.nodev."/" = {
    fsType = "tmpfs";
    mountOptions = [ "size=8G" "defaults" "mode=755" ];
  };
}
