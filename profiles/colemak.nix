{ config, lib, pkgs, ... }:

{
  services.kanata = {
    enable = true;
    keyboards."colemak" = {
      # TODO:
      # Super + SPC to switch

      # Heavily inspired by: https://dreymar.colemak.org/
      config = ''
        (defsrc
          grv  1    2    3    4    5    6    7    8    9    0    -    =    bspc
          tab  q    w    e    r    t    y    u    i    o    p    [    ]    \
          caps a    s    d    f    g    h    j    k    l    ;    '    ret
          lsft z    x    c    v    b    n    m    ,    .    /    rsft
          lctl lmet lalt           spc            ralt rmet rctl
        )


        (deflayer colemak-dh
          @grl  _    _    _    _    _    _    _    _    _    _    _    _    _
          _     q    w    f    p    b    j    l    u    y    ;    _    _    _
          _     a    r    s    t    g    m    n    e    i    o    _    _
          _     x    c    d    v    z    k    h    _    _    _    _
          _     _    _              _              _    _    _
        )


        (deflayer qwerty
          @grl  _    _    _    _    _    _    _    _    _    _    _    _    _
          _     q    w    e    r    t    y    u    i    o    p    _    _    _
          _     a    s    d    f    g    h    j    k    l    ;    _    _
          _     z    x    c    v    b    n    m    _    _    _    _
          _     _    _              _              _    _    _
        )


        (deflayer layers
          _    @qwr @clk _    _    _    _    _    _    _    _    _    _    _
          _    _    _    _    _    _    _    _    _    _    _    _    _    _
          _    _    _    _    _    _    _    _    _    _    _    _    _
          _    _    _    _    _    _    _    _    _    _    _    _
          _    _    _              _              _    _    _
        )

        (defalias
          ;; tap: backtick (grave), hold: toggle layer-switching layer while held
          grl (tap-hold 200 200 grv (layer-toggle layers))

          qwr (layer-switch qwerty)
          clk (layer-switch colemak-dh)
        )
      '';
    };
  };
}
