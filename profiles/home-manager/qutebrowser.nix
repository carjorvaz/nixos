{ ... }:

{
  programs.qutebrowser = {
    enable = true;

    settings = {
      auto_save.session = true;

      content = {
        canvas_reading = false;
        webgl = false;

        blocking.enabled = true;
        blocking.method = "both";
        blocking.adblock.lists = [
          "https://easylist.to/easylist/easylist.txt"
          "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"
          "https://easylist.to/easylist/easyprivacy.txt"
          "https://secure.fanboy.co.nz/fanboy-annoyance.txt"
          "https://easylist.to/easylist/fanboy-social.txt"
        ];
      };

      tabs.position = "left";
    };
  };
}
