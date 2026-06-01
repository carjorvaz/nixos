_:

{
  # Preserve the historical import behavior explicitly. NixOS warns that the
  # default will flip to false in 26.11 to reduce data-loss risk.
  boot.zfs.forceImportRoot = true;

  services.zfs = {
    trim.enable = true;
    autoScrub.enable = true;
  };
}
