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

  airUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKabE30sEDKJPK6Oq5zHn80qyakDSMqG3Y5tAfcUs2c9 cjv@air";
  trajanusUser = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF+Oo/MZBaS2tWj8/QGYFnYSnXT8i9AaTE4dJs4TRSUr cjv@trajanus";
  users = [
    airUser
    trajanusUser
  ];
in
{
  "cjvHashedPassword.age".publicKeys = systems ++ users;
  "hadrianusInitrdHostKey.age".publicKeys = [
    hadrianusSystem
  ]
  ++ users;
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

  # cl-olx-scraper (webhook/URL pairs, see flake.nix for format)
  "cl-olx-scraper-config.age".publicKeys = [
    piusSystem
  ]
  ++ users;

  # cl-ott Telegram API credentials and target chat/topic IDs
  "clOttTelegramEnv.age".publicKeys = [
    piusSystem
  ]
  ++ users;

  # Bearer token for cl-ott's loopback client API on pius
  "clOttClientApiToken.age".publicKeys = [
    piusSystem
  ]
  ++ users;

  # Jellyfin API key used by cl-ott integration services
  "jellyfinClOttApiKey.age".publicKeys = [
    piusSystem
  ]
  ++ users;

  # pdf-translator DeepSeek API key
  "deepseek-api-key.age".publicKeys = [
    piusSystem
    trajanusSystem
  ]
  ++ users;

  # Rustab Firefox AMO signing credentials
  "rustabWebExtCredentials.age".publicKeys = [
    trajanusSystem
  ]
  ++ users;

  # Recyclarr API keys for Radarr/Sonarr
  "radarrApiKey.age".publicKeys = [
    piusSystem
  ]
  ++ users;
  "sonarrApiKey.age".publicKeys = [
    piusSystem
  ]
  ++ users;

  # Syncoid SSH keys for ZFS replication
  "syncoidTrajanusKey.age".publicKeys = [
    trajanusSystem
  ]
  ++ users;
  "syncoidHadrianusKey.age".publicKeys = [
    hadrianusSystem
  ]
  ++ users;

  # Umami analytics session signing secret
  "umamiAppSecret.age".publicKeys = [
    hadrianusSystem
  ]
  ++ users;
}
