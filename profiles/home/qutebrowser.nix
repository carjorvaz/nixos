{ ... }:

{
  # TODO:
  # - brave search default engine
  # - firefox search engines (check config)
  # - hide youtube recommendations
  # - adblocking
  #   - and add custom lists
  # - userscripts https://github.com/qutebrowser/qutebrowser/blob/main/misc/userscripts/README.md :
  #   - bitwarden
  #   - readabilty
  #   - view in mpv
  # - bind copy link for org mode
  #   - config.bind("<y><o>", "yank inline [[{url}][{title}]]")
  #   - org-capture?
  home-manager.users.cjv = {
    programs.qutebrowser = {
      enable = true;

      settings = {
        # Restore previous tabs
        auto_save.session = true;

        # Enable ad-blocking
        content.blocking.method = "both";

        # Try to resist fingerprinting
        # https://wiki.archlinux.org/title/Qutebrowser#Minimize_fingerprinting
        content.canvas_reading = false;
        content.webgl = false;

        tabs.position = "left";
      };
    };
  };
}
