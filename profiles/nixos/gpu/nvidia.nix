{
  config,
  lib,
  ...
}:
{
  # Headless compute GPU (RTX 2080 Ti 22G). No display attached: the driver
  # stack exists purely for CUDA/LLM workloads, with persistence mode keeping
  # the card initialized across idle periods.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    # Open kernel module: NVIDIA-official (shipped in the same driver package,
    # supported since Turing, upstream's default going forward) and current.
    # Inference speed is identical to the closed flavor; this tracks upstream
    # and newer kernels better.
    open = true;
    nvidiaSettings = false;
    # Keep the card initialized so CUDA contexts survive idle periods.
    nvidiaPersistenced = true;
    powerManagement.enable = true;
    package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # nvidia-persistenced ships without an rpath to libnvidia-cfg.so.1, which
  # lives in the driver package's lib dir (not exposed via opengl-driver).
  systemd.services.nvidia-persistenced.environment.LD_LIBRARY_PATH =
    lib.mkForce "${config.hardware.nvidia.package}/lib";
}
