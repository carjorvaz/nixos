{ pkgs, ... }:

{
  services.xserver.videoDrivers = [ "modesetting" ];

  # Reference: https://wiki.nixos.org/wiki/Jellyfin#VAAPI_and_Intel_QSV
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-ocl
      intel-media-driver # Enable Hardware Acceleration
    ];
  };

  systemd.services.jellyfin.environment.LIBVA_DRIVER_NAME = "iHD";
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # May help if FFmpeg/VAAPI/QSV init fails (esp. on Arc with i915):
  hardware.enableRedistributableFirmware = true;
  boot.kernelParams = [ "i915.enable_guc=3" ];
}
