let
  aureliusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJLWOjxo8oCik6ijzLHxHHBJNRquFomnGA052EARUw2 root@aurelius";
  commodusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus  ";
  hadrianusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  t440System =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlO09UlgM2z4BKrw6GeveWdZuCX48Nzj57ujSvRYb+U root@t440";
  trajanusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHTIQ8jZEsUMNX7yrGpSECIB91B1t0EuX/k+fzLRBJ/v root@trajanus";
  systems = [ aureliusSystem commodusSystem hadrianusSystem t440System trajanusSystem ];

  commodusUser =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus";
  trajanusUser =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINeSrytHnGDHS4QQgYf+HxZkNdh79akg19kItGqA+9Z7 cjv@trajanus";
  users = [ commodusUser ];
in {
  "aureliusInitrdHostKey.age".publicKeys = [ aureliusSystem commodusUser ];
  "cjvHashedPassword.age".publicKeys = [ commodusSystem commodusUser trajanusSystem ];
  "mailCarlosHashedPassword.age".publicKeys = [ hadrianusSystem commodusUser ];
  "mailMafaldaHashedPassword.age".publicKeys = [ hadrianusSystem commodusUser ];
  "nextcloud-admin-pass.age".publicKeys = [ commodusSystem commodusUser ];
  "ovh.age".publicKeys =
    [ commodusSystem commodusUser hadrianusSystem t440System ];
}
