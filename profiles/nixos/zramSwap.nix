{ config, lib, pkgs, ... }:

{
  zramSwap = {
    enable = true;
    memoryPercent = 150;
  };
}
