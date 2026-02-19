{ ... }:

{
  hardware.graphics.enable = true;
  # hardware.amdgpu.opencl.enable = true;

  environment.sessionVariables = {
    # Multi-threaded OpenGL dispatch — benefits any GL app (browsers, compositors, video).
    mesa_glthread = "true";
    # Vulkan Graphics Pipeline Library — faster shader compilation for all Vulkan apps.
    RADV_PERFTEST = "gpl";
    # Ensure RADV is used over AMDVLK.
    AMD_VULKAN_ICD = "RADV";
  };
}
