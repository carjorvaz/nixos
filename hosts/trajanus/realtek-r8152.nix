{
  lib,
  stdenv,
  fetchFromGitHub,
  kernelPackages,
  kmod,
}:

let
  inherit (kernelPackages) kernel;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "realtek-r8152";
  version = "2.22.1-1";

  inherit (kernel) src;

  realtekSrc = fetchFromGitHub {
    owner = "awesometic";
    repo = "realtek-r8152-dkms";
    rev = finalAttrs.version;
    hash = "sha256-belWlCYiEW9WxxUw0/QGIL0bP2tNLxSyMV3rho6XpuU=";
  };

  postPatch = ''
    mkdir -p drivers/net/usb/realtek-r8152
    cp -r ${finalAttrs.realtekSrc}/src/. drivers/net/usb/realtek-r8152/
  '';

  nativeBuildInputs = [ kmod ] ++ kernel.moduleBuildDependencies;

  makeFlags = kernelPackages.kernelModuleMakeFlags ++ [
    "M=$(PWD)/drivers/net/usb/realtek-r8152"
    "INSTALL_MOD_PATH=$(out)"
    "INSTALL_MOD_DIR=updates"
  ];

  buildFlags = [ "modules" ];
  installTargets = [ "modules_install" ];

  meta = {
    description = "Realtek RTL8152/RTL8153/RTL8159 USB Ethernet kernel module";
    homepage = "https://github.com/awesometic/realtek-r8152-dkms";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
})
