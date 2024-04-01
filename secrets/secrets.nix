let
  aureliusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJLWOjxo8oCik6ijzLHxHHBJNRquFomnGA052EARUw2 root@aurelius";
  commodusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus  ";
  hadrianusSystem =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  t440System =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlO09UlgM2z4BKrw6GeveWdZuCX48Nzj57ujSvRYb+U root@t440";
  systems = [ aureliusSystem commodusSystem hadrianusSystem t440System ];

  commodusUser =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus";
  users = [ commodusUser ];
in {
  "aureliusInitrdHostKey.age".publicKeys = [ aureliusSystem commodusUser ];
  "cjvHashedPassword.age".publicKeys = [ commodusSystem commodusUser ];
  "mailCarlosHashedPassword.age".publicKeys = [ hadrianusSystem commodusUser ];
  "mailMafaldaHashedPassword.age".publicKeys = [ hadrianusSystem commodusUser ];
  "nextcloud-admin-pass.age".publicKeys = [ commodusSystem commodusUser ];
  "ovh.age".publicKeys =
    [ commodusSystem commodusUser hadrianusSystem t440System ];
}
