{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Syncoid transfer optimizations (compression and buffering)
  environment.systemPackages = with pkgs; [ lzop mbuffer ];

  services.sanoid = {
    enable = true;

    # Default snapshot template
    templates.default = {
      frequently = 4;  # every 15 minutes, keep 4 (1 hour)
      hourly = 24;     # every hour, keep 24 (1 day)
      daily = 7;       # every day, keep 7 (1 week)
      weekly = 4;      # every week, keep 4 (1 month)
      monthly = 12;    # every month, keep 12 (1 year)
      yearly = 2;      # every year, keep 2
      autosnap = true;
      autoprune = true;
    };
  };
}
