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

        # Try to resist fingerprinting
        # https://wiki.archlinux.org/title/Qutebrowser#Minimize_fingerprinting
        content = {
          canvas_reading = false;
          webgl = false;

          # Enable ad-blocking
          blocking.enabled = true;
          blocking.method = "both";
          blocking.adblock.lists = [
            # TODO lists I usually use in ublock origin
            "https://easylist.to/easylist/easylist.txt"
            "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"
            "https://easylist.to/easylist/easyprivacy.txt"
            "https://secure.fanboy.co.nz/fanboy-annoyance.txt"
            "https://easylist.to/easylist/fanboy-social.txt"
          ];
        };

        tabs.position = "left";

        # url.searchengines = {
        #   "DEFAULT" = "https://search.brave.com/search?q={}";
        # };
      };
    };
  };
}
