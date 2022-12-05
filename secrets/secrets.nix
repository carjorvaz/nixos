let
  gallusUser =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMxNtlOg5VM8xN3XYfBGY3wIXrJ0vF5fBpc8s2NsLG9/ cjv@gallus";
  users = [ gallusUser ];

  gallusSystem =
    # TODO Experimentar usar o .pub do host que já existia
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjVjQULxTJ+NN5ekG0HLpnkyPFIAwbNCQ5EOZ4cSfCt root@gallus";
  systems = [ gallusSystem ];
in {
  # "secretFile.age".publicKeys = users ++ systems;
}
