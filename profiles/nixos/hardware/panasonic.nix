{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./japaneseKeyboard.nix ];

  # Will kernel panic on suspend without this
  boot.kernelParams = [ "i915.enable_dc=0" ];

  services.xserver = {
    libinput.enable = false;

    synaptics = {
      enable = true;

      # References:
      # - https://gist.github.com/ivan/c35e798d4f32e37c1714ec5beec30d16
      # - https://wiki.archlinux.org/title/Touchpad_Synaptics#The_touchpad_is_not_working,_Xorg.0.log_shows_%22Query_no_Synaptics:_6003C8%22

      # xorg already has mouse acceleration ("pointer feedback"), so don't
      # let synaptics change speed.
      minSpeed = "1.0";
      maxSpeed = "1.0";

      # Default is 200/((WIDTH**2+HEIGHT**2)**0.5) and it may be better not
      # to mess with AccelFactor.
      accelFactor = "0.003";

      # Natural scrolling
      # scrollDelta = -75;
      twoFingerScroll = true;

      fingersMap = [
        1
        3
        2
      ];

      additionalOptions = ''
        Option "CircularScrolling" "on"
        Option "CircularPad" "on"

        # synaptics is too sensitive in general and MinSpeed=1.0 MaxSpeed=1.0
        # makes it worse, so use ConstantDeceleration (this is just a divisor!)
        # to slow it down to make precise movement possible.
        #
        # See also https://bugs.freedesktop.org/show_bug.cgi?id=38998
        # ("Synaptics driver imposes minimum speed")
        Option "ConstantDeceleration" "3"
      '';

      # We've slowed down the cursor quite a bit, so we need more than the
      # default acceleration of 2/1 to move it across the screen; add this
      # to ~/.xinitrc:
      #
      # xset m 4/1 0
      #
      # If your screen is big (these parameters were tested on 13" 1600x900),
      # you may need to increase the acceleration or decrease the
      # ConstantDeceleration so that you can flick the cursor across the screen.
    };
  };
}
