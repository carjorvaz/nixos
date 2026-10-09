{ pkgs, ... }:

{
  services.xserver.videoDrivers = [ "modesetting" ];

  # Reference: https://wiki.nixos.org/wiki/Jellyfin#VAAPI_and_Intel_QSV
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      # intel-ocl's upstream download has returned 403 since 2024 and the
      # package is not in any binary cache; the maintained NEO runtime covers
      # this host's Gen9.5 iGPU (UHD 630).
      intel-compute-runtime-legacy1
      intel-media-driver # Enable Hardware Acceleration
    ];
  };

  systemd.services.jellyfin.environment.LIBVA_DRIVER_NAME = "iHD";
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # May help if FFmpeg/VAAPI/QSV init fails (esp. on Arc with i915):
  hardware.enableRedistributableFirmware = true;
  boot.kernelParams = [ "i915.enable_guc=3" ];
}
