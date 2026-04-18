{ config, ... }:

{
  home-manager.users.cjv.programs.swaylock = {
    enable = true;
    settings = {
      # Needed for fingerprint to work with swaylock.
      # Press enter than tap finger.
      ignore-empty-password = false;
      show-failed-attempts = true;

      font = "monospace";
      image = "${config.graphical.theme.wallpaper}";

      # Keep the shared wallpaper and drive the chrome from the active palette.
      color = "${config.graphical.theme.palette.bg}55";
      indicator-radius = "100";
      indicator-thickness = "50";
      line-color = "ffffff22";
      line-clear-color = "00000000";
      line-caps-lock-color = "00000000";
      line-ver-color = "00000000";
      line-wrong-color = "00000000";
      inside-color = "${config.graphical.theme.palette.bg}55";
      ring-color = "${config.graphical.theme.palette.border}55";
      ring-ver-color = "${config.graphical.theme.palette.info}55";
      key-hl-color = "${config.graphical.theme.palette.accent}66";
      separator-color = "00000000";
      layout-bg-color = "00000000";
      layout-border-color = "00000000";
      inside-ver-color = "ffffff22";
      font-size = "24";
      text-color = "${config.graphical.theme.palette.fg}FF";
      text-clear-color = "${config.graphical.theme.palette.fg}FF";
      text-caps-lock-color = "${config.graphical.theme.palette.fg}FF";
      text-ver-color = "${config.graphical.theme.palette.fg}FF";
      text-wrong-color = "${config.graphical.theme.palette.fg}FF";
    };
  };
}
