{ ... }:

{
  # Create AltGr keys
  services.kanata = {
    enable = true;
    # Find what the pressed key is with xev or wev and translate with:
    # https://github.com/jtroo/kanata/blob/main/parser/src/keys/mod.rs
    keyboards.jp.config = ''
      (defsrc
        henkan kana menu
      )

      (deflayer default
        ralt ralt ralt
      )
    '';
  };
}
