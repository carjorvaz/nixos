let
  commodusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus  ";
  hadrianusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  t440System =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII6+gZmLDcxvCaiXj1grZEltbsfe0u0f5UKDTnDdIsoZ root@t440";
  systems = [ commodusSystem hadrianusSystem t440System ];

  commodusUser =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodu  ";
  users = [ commodusUser ];
in {
  "mailCarlosHashedPassword.age".publicKeys = [ commodusUser hadrianusSystem ];
  "mailMafaldaHashedPassword.age".publicKeys = [ commodusUser hadrianusSystem ];
  "nextcloud-db-pass.age".publicKeys = [ commodusSystem commodusUser ];
  "nextcloud-admin-pass.age".publicKeys = [ commodusSystem commodusUser ];
  "ovh.age".publicKeys =
    [ commodusSystem commodusUser hadrianusSystem t440System ];
}
