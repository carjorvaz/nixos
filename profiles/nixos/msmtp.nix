{ pkgs, ... }:

{
  programs.msmtp = {
    enable = true;
    setSendmail = true;

    defaults = {
      port = 587;
      tls = true;
    };
  };

  services.zfs.zed.settings.ZED_EMAIL_PROG = "${pkgs.msmtp}/bin/msmtp";
}
