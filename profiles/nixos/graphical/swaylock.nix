{ ... }:

{
  home-manager.users.cjv.programs.swaylock = {
    enable = true;
    settings = {
      # Needed for fingerprint to work with swaylock.
      # Press enter than tap finger.
      ignore-empty-password = false;
      show-failed-attempts = true;

      font = "monospace";
      image = "${./wallpaper.jpg}";

      # https://github.com/swayos/swayos.github.io/blob/main/home/.swaylock/config
      color = "dcdccc55";
      indicator-radius = "100";
      indicator-thickness = "50";
      line-color = "ffffff22";
      line-clear-color = "00000000";
      line-caps-lock-color = "00000000";
      line-ver-color = "00000000";
      line-wrong-color = "00000000";
      inside-color = "dcdccc55";
      ring-color = "dcdcdc55";
      ring-ver-color = "33445555";
      key-hl-color = "FFFFFF66";
      separator-color = "00000000";
      layout-bg-color = "00000000";
      layout-border-color = "00000000";
      inside-ver-color = "ffffff22";
      font-size = "24";
      text-color = "FFFFFFFF";
      text-clear-color = "FFFFFFFF";
      text-caps-lock-color = "FFFFFFFF";
      text-ver-color = "FFFFFFFF";
      text-wrong-color = "FFFFFFFF";
    };
  };
}
