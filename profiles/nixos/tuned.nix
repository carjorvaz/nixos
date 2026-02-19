{ ... }:

{
  # Only override power-saver on battery; balanced/performance stay as profiles section
  services.tuned = {
    enable = true; 

    ppdSettings = {
      main.default = "balanced";

      profiles = {
        balanced = "desktop";
        performance = "throughput-performance";
        power-saver = "desktop-powersave";
      };

      battery.power-saver = "laptop-battery-powersave";
    };
  };
}
