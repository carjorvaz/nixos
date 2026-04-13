{ ... }:

{
  homebrew = {
    taps = [
      "osx-cross/arm"
      "osx-cross/avr"
      "qmk/qmk"
    ];

    brews = [
      "qmk"
      # QMK dependencies
      "avr-binutils"
      "avr-gcc@8"
      "boost"
      "confuse"
      "hidapi"
      "libftdi"
      "libusb-compat"
      "avrdude"
      "bootloadhid"
      "clang-format"
      "dfu-programmer"
      "dfu-util"
      "libimagequant"
      "libraqm"
      "pillow"
      "teensy_loader_cli"
      "osx-cross/arm/arm-none-eabi-binutils"
      "osx-cross/arm/arm-none-eabi-gcc@8"
      "osx-cross/avr/avr-gcc@9"
      "qmk/qmk/hid_bootloader_cli"
      "qmk/qmk/mdloader"
    ];

    casks = [
      "qmk-toolbox"
      "vial"
    ];
  };
}
