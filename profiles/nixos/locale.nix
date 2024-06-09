{
  config,
  lib,
  pkgs,
  ...
}:

{
  time.timeZone = "Europe/Lisbon";

  i18n = {
    defaultLocale = "en_US.utf8";
    extraLocaleSettings = {
      LC_ADDRESS = "pt_PT.utf8";
      LC_IDENTIFICATION = "pt_PT.utf8";
      LC_MEASUREMENT = "pt_PT.utf8";
      LC_MONETARY = "pt_PT.utf8";
      LC_NAME = "pt_PT.utf8";
      LC_NUMERIC = "pt_PT.utf8";
      LC_PAPER = "pt_PT.utf8";
      LC_TELEPHONE = "pt_PT.utf8";
      LC_TIME = "pt_PT.utf8";
    };
  };

  environment.systemPackages = with pkgs; [
    aspell
    (aspellWithDicts (
      ds: with ds; [
        en
        en-computers
        en-science
        pt_PT
      ]
    ))
    hunspell
  ];
}
