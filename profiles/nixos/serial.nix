{ pkgs, ... }:

let
  # Report the attached terminal's real size to the serial tty. Serial
  # consoles keep the geometry they had at boot (usually 80x24), so TUIs
  # render into a corner once a BMC/SOL client attaches with a larger window.
  # Copied from numtide/srvos nixos/common/serial.nix.
  resize = pkgs.writeShellScriptBin "resize" ''
    export PATH=${pkgs.coreutils}/bin
    if [ ! -t 0 ]; then
      # Not interactive.
      exit 0
    fi
    TTY="$(tty)"
    if [[ "$TTY" != /dev/ttyS* ]] && [[ "$TTY" != /dev/ttyAMA* ]] && [[ "$TTY" != /dev/ttySIF* ]]; then
      # Not a known serial console.
      exit 0
    fi

    old=$(stty -g)
    stty raw -echo min 0 time 5

    printf '\0337\033[r\033[999;999H\033[6n\0338' > /dev/tty
    IFS='[;R' read -r _ rows cols _ < /dev/tty

    stty "$old"
    stty cols "$cols" rows "$rows"
  '';
in
{
  # systemd-getty-generator creates serial-getty@<port> from the kernel
  # `console=` arguments. The default TERM (vt220) loses colors and the
  # capabilities htop/tmux/nvim expect.
  systemd.services."serial-getty@".environment.TERM = "xterm-256color";

  environment = {
    systemPackages = [ resize ];

    # /etc/profile runs before the bash -> fish exec hook, so this covers fish
    # logins too. The script exits immediately on non-serial ttys.
    loginShellInit = "${resize}/bin/resize";
  };
}
