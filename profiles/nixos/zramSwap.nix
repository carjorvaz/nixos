{ ... }:

{
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 150;
  };

  # https://github.com/NixOS/nixpkgs/pull/351002/files
  boot.kernel.sysctl = {
    "vm.swappiness" = 150;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    "vm.page-cluster" = 0;
    "vm.vfs_cache_pressure" = 50;
  };
}
