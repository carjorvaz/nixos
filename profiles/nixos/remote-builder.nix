_:

{
  nix.sshServe = {
    enable = true;
    keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ9+9Qazu/2mI49zKjRuxI2MOCZ96OGOLVadHj1WXjUT builder@air"
    ];
    protocol = "ssh-ng";
    trusted = true;
  };
}
