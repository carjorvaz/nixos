let
  aureliusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus  ";
  hadrianusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  t440System = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlO09UlgM2z4BKrw6GeveWdZuCX48Nzj57ujSvRYb+U root@t440";
  trajanusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbiiJr+X+25mBGrcKj+2i8ESORUYAv/FpeS+7LCb+nj root@trajanus";
  systems = [
    aureliusSystem
    hadrianusSystem
    t440System
    trajanusSystem
  ];

  commodusUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus";
  trajanusUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBK2AsWCLGKxGjkXbIUD8lIV0+48qJFNV9h7FfLLx16f cjv@trajanus";
  users = [ commodusUser ];
in
{
  "mailCarlosHashedPassword.age".publicKeys = [
    hadrianusSystem
    commodusUser
  ];
  "mailMafaldaHashedPassword.age".publicKeys = [
    hadrianusSystem
    commodusUser
  ];
  "mailAureliusPassword.age".publicKeys = [
    aureliusSystem
    commodusUser
  ];
  "mailAureliusHashedPassword.age".publicKeys = [
    hadrianusSystem
    commodusUser
  ];
  "nextcloud-admin-pass.age".publicKeys = [
    aureliusSystem
    commodusUser
  ];
  "ovh.age".publicKeys = [
    aureliusSystem
    commodusUser
    hadrianusSystem
    t440System
  ];
  "plausibleAdminPassword.age".publicKeys = [
    aureliusSystem
    commodusUser
  ];
  "plausibleSecretKeybase.age".publicKeys = [
    aureliusSystem
    commodusUser
  ];
}
