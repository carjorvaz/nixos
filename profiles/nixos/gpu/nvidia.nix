{
  config,
  lib,
  pkgs,
  ...
}:

{
  nixpkgs.config.nvidia.acceptLicense = true;

  # Make sure graphics are enabled
  hardware.graphics.enable = true;

  # Tell Xorg to use the nvidia driver (also valid for Wayland)
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # Use the NVidia open source kernel module (not to be confused with the
    # independent third-party "nouveau" open source driver).
    # Support is limited to the Turing and later architectures. Full list of
    # supported GPUs is at:
    # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus
    # Only available from driver 515.43.04+
    # Currently alpha-quality/buggy, so false is currently the recommended setting.
    open = lib.mkDefault false;

    # Optionally, you may need to select the appropriate driver version for your specific GPU.
    package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.stable;
    # package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.beta;
    # package = config.boot.kernelPackages.nvidiaPackages.legacy_470;
  };

  home-manager.users.cjv.wayland.windowManager.hyprland.settings = {
    env = [
      "LIBVA_DRIVER_NAME,nvidia"
      "__GLX_VENDOR_LIBRARY_NAME,nvidia"
    ];

    cursor.no_hardware_cursors = true;
  };
}
