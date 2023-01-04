let
  batatusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA6lzje83dKBww7eAQydUzuG5qhTrfPM6oIRdrmSf1y7 root@batatus";
  commodusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus  ";
  gallusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjVjQULxTJ+NN5ekG0HLpnkyPFIAwbNCQ5EOZ4cSfCt root@gallus";
  hadrianusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  systems = [ commodusSystem gallusSystem hadrianusSystem ];

  commodusUser =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodu  ";
  gallusUser =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMxNtlOg5VM8xN3XYfBGY3wIXrJ0vF5fBpc8s2NsLG9/ cjv@gallus";
  users = [ commodusUser gallusUser ];
in {
  "ovh.age".publicKeys =
    [ batatusSystem commodusSystem commodusUser hadrianusSystem ];
}
