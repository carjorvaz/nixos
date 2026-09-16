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
    # Proprietary kernel module, not the open one: this card hit the Turing
    # GSP Xid 119 -> 154 fault mode twice in two days on the open module +
    # GSP (595.71.05), each time costing a host reboot, and
    # NVreg_EnableGpuFirmware=0 is a no-op when `open` is true (nixpkgs also
    # asserts GSP cannot be disabled on the open module). Inference speed is
    # identical; only the kernel-module derivation moves.
    open = false;
    # Keep the GSP RISC-V core out of the path entirely.
    gsp.enable = false;
    moduleParams.nvidia.NVreg_EnableGpuFirmware = 0;
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
