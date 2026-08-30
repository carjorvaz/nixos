let
  piusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55 root@commodus";
  hadrianusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFI1Mcb4pU6+2ZCmS5wBJqb4oLZdcSxryvTOUf9ZLxIU root@hadrianus";
  juliusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINEIQuRyifNhgbFI8ufu22kcj1Jx8WkTRlpl2HIFGZBZ root@julius";
  trajanusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGoGQXDEcTd0T72g+YRzoQO30E09BvbfD9eBtcl3NRf root@trajanus";
  tiberiusSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICX0M2EnM7JcZfCi9w7OkXht64HRRd0/BJxiIGbkSEJg root@tiberius";
  phoneputerSystem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKdeg5qEW5tEXXFbsVXJOBXgULiwdZwaX4bYxMTqVOrC root@phoneputer";
  systems = [
    piusSystem
    hadrianusSystem
    juliusSystem
    trajanusSystem
    tiberiusSystem
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
  "phoneputerIwdMacSeed.age".publicKeys = [ phoneputerSystem ] ++ users;
  "phoneputerWirelessPrimary.age".publicKeys = [ phoneputerSystem ] ++ users;
  "phoneputerWirelessSecondary.age".publicKeys = [ phoneputerSystem ] ++ users;
  "piusInitrdHostKey.age".publicKeys = [
    piusSystem
  ]
  ++ users;
  "hadrianusInitrdHostKey.age".publicKeys = [
    hadrianusSystem
  ]
  ++ users;
  "trajanusInitrdHostKey.age".publicKeys = [
    trajanusSystem
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

  # Telegram API credentials and peer IDs shared by pius services
  "piusTelegramEnv.age".publicKeys = [
    piusSystem
  ]
  ++ users;

  # Bearer token for ott-rs's loopback client API on pius
  "ottTvClientApiToken.age".publicKeys = [
    piusSystem
  ]
  ++ users;

  # Hindsight API raw bearer token on pius
  "hindsightApiToken.age".publicKeys = [ piusSystem ] ++ users;

  # pdf-translator DeepSeek API key
  "deepseek-api-key.age".publicKeys = [
    piusSystem
    trajanusSystem
  ]
  ++ users;

  # Brave Search API key (omp web_search, etc.)
  "brave-search-api-key.age".publicKeys = users;

  # Session token shared by the trajanus Hermes backend and Desktop on air
  "hermesDashboardSessionToken.age".publicKeys = [ trajanusSystem ] ++ users;

  # Private Lisp corpus share credential
  "terrenoEnv.age".publicKeys = [
    piusSystem
    hadrianusSystem
  ]
  ++ users;
  "terrenoHtpasswd.age".publicKeys = [
    piusSystem
    hadrianusSystem
  ]
  ++ users;
  "lispCorpusShareHtpasswd.age".publicKeys = [
    piusSystem
    hadrianusSystem
  ]
  ++ users;
  "lispCorpusSharePassword.age".publicKeys = [
    piusSystem
    hadrianusSystem
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

  # Offline recovery copy of pius Secure Boot signing keys
  "piusSecureBootKeys.age".publicKeys = users;
}
