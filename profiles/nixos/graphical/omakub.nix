{
  pkgs,
  ...
}:

{
  environment.systemPackages = with pkgs; [
    gnomeExtensions.just-perfection
    gnomeExtensions.blur-my-shell
    gnomeExtensions.space-bar
    gnomeExtensions.undecorate
  ];

  home-manager.users.cjv =
    { lib, ... }:
    {
      # Use `dconf watch /` to track stateful changes you are doing, then set them here.
      dconf.settings = {
        "org/gnome/desktop/wm/preferences" = {
          focus-mode = "mouse";
          num-workspaces = 9;
        };
      };

      "org/gnome/shell/keybindings" = lib.pipe (lib.range 1 9) [
        (lib.map toString)
        (lib.map (i: [
          (lib.nameValuePair "switch-to-application-${i}" (
            lib.hm.gvariant.mkEmptyArray lib.hm.gvariant.type.string
          ))
        ]))
        lib.flatten
        builtins.listToAttrs
      ];

      "org/gnome/desktop/wm/keybindings" =
        lib.pipe (lib.range 1 9) [
          (lib.map toString)
          (lib.map (i: [
            (lib.nameValuePair "switch-to-workspace-${i}" [ "<Super>${i}" ])
            (lib.nameValuePair "move-to-workspace-${i}" [ "<Shift><Super>${i}" ])
          ]))
          lib.flatten
          builtins.listToAttrs
        ]
        // {
          close = [ "<Shift><Super>q" ];
        };

      "org/gnome/mutter" = {
        center-new-windows = true;
        current-workspace-only = true;
        dynamic-workspaces = false;
        workspaces-only-on-primary = true;
      };

      "org/gnome/settings-daemon/plugins/media-keys" = {
        screensaver = [ "<Super>o" ];
      };

      # STATE: Needs to be created manually
      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
        binding = "<Super>Return";
        command = "alacritty";
      };

      "org/gnome/shell" = {
        # https://wiki.nixos.org/wiki/GNOME#Managing_extensions
        disable-user-extensions = false; # enables user extensions
        enabled-extensions = [
          pkgs.gnomeExtensions.just-perfection.extensionUuid
          pkgs.gnomeExtensions.blur-my-shell.extensionUuid
          pkgs.gnomeExtensions.space-bar.extensionUuid
          pkgs.gnomeExtensions.undecorate.extensionUuid
        ];
      };

      # Configure Just Perfection
      "org/gnome/shell/extensions/just-perfection" = {
        animation = 2;
        dash-app-running = true;
        workspace = true;
        workspace-popup = false;
      };
      # Configure Blur My Shell
      "org/gnome/shell/extensions/blur-my-shell/appfolder".blur = false;
      "org/gnome/shell/extensions/blur-my-shell/lockscreen".blur = false;
      "org/gnome/shell/extensions/blur-my-shell/screenshot".blur = false;
      "org/gnome/shell/extensions/blur-my-shell/window-list".blur = false;
      "org/gnome/shell/extensions/blur-my-shell/panel".blur = false;
      "org/gnome/shell/extensions/blur-my-shell/overview".blur = true;
      "org/gnome/shell/extensions/blur-my-shell/overview".pipeline = "pipeline_default";
      "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".blur = true;
      "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".brightness = "0/6";
      "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".sigma = 30;
      "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".static-blur = true;
      "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".style-dash-to-dock = 0;
      # Configure Space Bar
      "org/gnome/shell/extensions/space-bar/behavior".smart-workspace-names = false;
      "org/gnome/shell/extensions/space-bar/shortcuts".enable-activate-workspace-shortcuts = false;
      "org/gnome/shell/extensions/space-bar/shortcuts".enable-move-to-workspace-shortcuts = true;
      "org/gnome/shell/extensions/space-bar/shortcuts".open-menu =
        lib.hm.gvariant.mkEmptyArray lib.hm.gvariant.type.string;
    };
}
