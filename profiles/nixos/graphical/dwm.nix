{ config, lib, pkgs, ... }:

# TODO:
# - slock dpms patch 2 seconds timeout https://tools.suckless.org/slock/patches/dpms/

{
  imports = [ ./common.nix ];

  nixpkgs.overlays = [
    # TODO all very similar, abstract with a function?
    (self: super: {
      dmenu = super.dmenu.overrideAttrs (oldAttrs: rec {
        patches = [ ./suckless/patches/dmenu-qalc-5.2.diff ];

        configFile = super.writeText "config.h"
          (builtins.readFile ./suckless/dmenu-5.3-config.h);
        postPatch = ''
          ${oldAttrs.postPatch}
          cp ${configFile} config.h'';
      });

      dwm = super.dwm.overrideAttrs (oldAttrs: rec {
        patches = [
          # Move cursor to focused window/screen
          (pkgs.fetchpatch {
            url = "https://dwm.suckless.org/patches/warp/dwm-warp-6.4.diff";
            sha256 = "sha256-8z41ld47/2WHNJi8JKQNw76umCtD01OUQKSr/fehfLw=";
          })
        ];

        configFile = super.writeText "config.h"
          (builtins.readFile ./suckless/dwm-6.5-config.h);
        postPatch = ''
          ${oldAttrs.postPatch}
          cp ${configFile} config.h'';
      });

      st = super.st.overrideAttrs (oldAttrs: rec {
        patches = [
          (pkgs.fetchpatch {
            url =
              "https://st.suckless.org/patches/anysize/st-expected-anysize-0.9.diff";
            sha256 = "sha256-q21HEZoTiVb+IIpjqYPa9idVyYlbG9RF3LD6yKW4muo=";
          })
        ];

        configFile = super.writeText "config.h"
          (builtins.readFile ./suckless/st-0.9.2-config.h);
        postPatch = ''
          ${oldAttrs.postPatch}
          cp ${configFile} config.h'';
      });
    })
  ];

  services = {
    xserver.windowManager.dwm.enable = true;

    dwm-status = {
      enable = true;

      # TODO audio?
      order = lib.mkDefault [ "time" ];

      extraConfig = ''
        separator = " | "
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    bemoji
    dmenu
    st
    stalonetray
  ];

  programs = {
    slock.enable = true;

    # To lock: loginctl lock-session
    # https://discourse.nixos.org/t/slock-when-suspend/22457
    xss-lock = {
      enable = true;
      lockerCommand = "/run/wrappers/bin/slock";
    };
  };
}
