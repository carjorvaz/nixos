{ config, lib, pkgs, ... }:

{
  services.wordpress.webserver = "nginx";

  environment.persistence."/persist".directories =
    [ "/var/lib/mysql" "/var/lib/wordpress" ];
}
