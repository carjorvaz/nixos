{ config, lib, pkgs, ... }:

{
  services.kanata = {
    enable = true;
    keyboards."colemak" = {
      # TODO:
      # - Super + SPC to switch between colemak and qwerty
      # - wide extend (e wide em geral)
      # - iso layout?

      # Heavily inspired by: https://dreymar.colemak.org/
      config = ''
        (defsrc
          grv     1    2    3    4    5    6    7    8    9    0    -    =    bspc
          tab     q    w    e    r    t    y    u    i    o    p    [    ]    \
          caps    a    s    d    f    g    h    j    k    l    ;    '    ret
          lsft      z    x    c    v    b    n    m    ,    .    /    rsft
          lctl    lmet lalt           spc            ralt rmet cmp  rctl
        )

        (deflayer colemak-caw
          _     _    _    _    _    _    _    =    7    8    9    0    -    _
          _     q    w    f    p    b    [    j    l    u    y    ;    '    \
          _     a    r    s    t    g    ]    m    n    e    i    o    _
          _       x    c    d    v    z    /    k    h    ,    .    _
          _     _    _              _              _    _    _    _
        )

;;        (deflayer colemak-ca
;;          @grl  _    _    _    _    _    _    _    _    _    _    _    _    _
;;          _     q    w    f    p    b    j    l    u    y    ;    _    _    _
;;          @ext  a    r    s    t    g    m    n    e    i    o    _    _
;;          _     x    c    d    v    z    k    h    _    _    _    _
;;          _     _    _              _              _    _    _
;;        )
;;
;;        (deflayer qwerty
;;          @grl  _    _    _    _    _    _    _    _    _    _    _    _
;;          _     _    _    _    _    _    _    _    _    _    _    _    _    _
;;          _     q    w    e    r    t    y    u    i    o    p    _    _    _
;;          @ext  a    s    d    f    g    h    j    k    l    ;    _    _
;;          _       z    x    c    v    b    n    m    _    _    _    _
;;          _     _    _              _              _    _    _    _
;;        )
;;
;;        (deflayer extend
;;          _        f1   f2   f3   f4   f5   f6   f7   f8   f9  f10   f11  f12  _
;;          _        esc  @bk  @fnd @fw  ins  pgup home up   end  menu prnt slck _
;;          _        lalt lmet lsft lctl ralt pgdn lft  down rght del  caps _
;;          _          @cut @cpy  tab  @pst @udo pgdn bks  lsft lctl comp _
;;          _        _    _              ret            _    _    _    _
;;        )
;;
;;        (deflayer empty
;;          _        _    _    _    _    _    _    _    _    _    _    _    _    _
;;          _        _    _    _    _    _    _    _    _    _    _    _    _    _
;;          _        _    _    _    _    _    _    _    _    _    _    _    _
;;          _          _    _    _    _    _    _    _    _    _    _    _
;;          _        _    _              _              _    _    _    _
;;        )
;;
;;        (deflayer layers
;;          _    @qwr @clk _    _    _    _    _    _    _    _    _    _    _
;;          _    _    _    _    _    _    _    _    _    _    _    _    _    _
;;          _    _    _    _    _    _    _    _    _    _    _    _    _
;;          _    _    _    _    _    _    _    _    _    _    _    _
;;          _    _    _              _              _    _    _
;;        )
;;
;;        (defalias
;;          ;; tap: backtick (grave), hold: toggle layer-switching layer while held
;;          grl (tap-hold 200 200 grv (layer-toggle layers))
;;
;;          qwr (layer-switch qwerty)
;;          clk (layer-switch colemak-caw)
;;
;;          ext  (layer-toggle extend) ;; Bind 'ext' to the Extend Layer
;;
;;          cpy C-c
;;          pst C-v
;;          cut C-x
;;          udo C-z
;;          all C-a
;;          fnd C-f
;;          bk Back
;;          fw Forward
;;        )
;;      '';

    };
  };
}
