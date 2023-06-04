let
  commodusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus  ";
  hadrianusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  systems = [ commodusSystem hadrianusSystem ];

  commodusUser =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodu  ";
  users = [ commodusUser ];
in {
  "mailCarlosHashedPassword.age".publicKeys = [ commodusUser hadrianusSystem ];
  "mailMafaldaHashedPassword.age".publicKeys = [ commodusUser hadrianusSystem ];
  "nextcloud-db-pass.age".publicKeys = [ commodusSystem commodusUser ];
  "nextcloud-admin-pass.age".publicKeys = [ commodusSystem commodusUser ];
  "ovh.age".publicKeys = [ commodusSystem commodusUser hadrianusSystem ];

  "nebulaRomeCaCrt.age".publicKeys = systems;
  "nebulaRomeCommodusCrt.age".publicKeys = [ commodusSystem ];
  "nebulaRomeCommodusKey.age".publicKeys = [ commodusSystem ];
  "nebulaRomeHadrianusCrt.age".publicKeys = [ hadrianusSystem ];
  "nebulaRomeHadrianusKey.age".publicKeys = [ hadrianusSystem ];
}
