let
  aureliusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7f0hFBGTlQo533O73cpWP+7lQqncdYpxS2/qtYbv3A root@aurelius";
  piusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus  ";
  hadrianusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  t440System = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlO09UlgM2z4BKrw6GeveWdZuCX48Nzj57ujSvRYb+U root@t440";
  trajanusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbiiJr+X+25mBGrcKj+2i8ESORUYAv/FpeS+7LCb+nj root@trajanus";
  systems = [
    piusSystem
    hadrianusSystem
    t440System
    trajanusSystem
  ];

  aureliusUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICrco+nZ1DgpsNHntTzMeo626GglxwLKks3XL82XD0kZ cjv@aurelius";
  commodusUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus";
  trajanusUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBK2AsWCLGKxGjkXbIUD8lIV0+48qJFNV9h7FfLLx16f cjv@trajanus";
  users = [
    commodusUser
    trajanusUser
  ];
in
{
  "aureliusInitrdHostKey.age".publicKeys = [ aureliusSystem ] ++ users;
  "mailCarlosHashedPassword.age".publicKeys = [
    hadrianusSystem
    commodusUser
  ];
  "mailMafaldaHashedPassword.age".publicKeys = [
    hadrianusSystem
    commodusUser
  ];
  "mailPiusPassword.age".publicKeys = [
    piusSystem
    commodusUser
  ];
  "mailPiusHashedPassword.age".publicKeys = [
    hadrianusSystem
    commodusUser
  ];
  "nextcloud-admin-pass.age".publicKeys = [
    piusSystem
    commodusUser
  ];
  "ovh.age".publicKeys = [
    piusSystem
    commodusUser
    hadrianusSystem
    t440System
  ];
  "plausibleAdminPassword.age".publicKeys = [
    piusSystem
    commodusUser
  ];
  "plausibleSecretKeybase.age".publicKeys = [
    piusSystem
    commodusUser
  ];
  "wgrnlTrajanus.age".publicKeys = [
    trajanusSystem
    trajanusUser
  ];
}
