let
  piusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus  ";
  hadrianusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  juliusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINEIQuRyifNhgbFI8ufu22kcj1Jx8WkTRlpl2HIFGZBZ root@julius";
  trajanusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGoGQXDEcTd0T72g+YRzoQO30E09BvbfD9eBtcl3NRf root@trajanus";
  systems = [
    piusSystem
    hadrianusSystem
    juliusSystem
    trajanusSystem
  ];

  macUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKabE30sEDKJPK6Oq5zHn80qyakDSMqG3Y5tAfcUs2c9 cjv@mac";
  trajanusUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF+Oo/MZBaS2tWj8/QGYFnYSnXT8i9AaTE4dJs4TRSUr cjv@trajanus";
  users = [
    macUser
    trajanusUser
  ];
in
{
  "mailCarlosHashedPassword.age".publicKeys = [
    hadrianusSystem
  ]
  ++ users;
  "mailMafaldaHashedPassword.age".publicKeys = [
    hadrianusSystem
  ]
  ++ users;
  "mailPiusPassword.age".publicKeys = [
    piusSystem
  ]
  ++ users;
  "mailPiusHashedPassword.age".publicKeys = [
    hadrianusSystem
  ]
  ++ users;
  "nextcloud-admin-pass.age".publicKeys = [
    piusSystem
  ]
  ++ users;
  "ovh.age".publicKeys = systems ++ users;
  "plausibleSecretKeybase.age".publicKeys = [
    piusSystem
  ]
  ++ users;
}
