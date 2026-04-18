{ ... }:
{
  # Impermanence bind mounts must be available before stage 2.
  fileSystems."/persist".neededForBoot = true;

  environment.persistence."/persist" = {
    hideMounts = true;
    files = [
      "/etc/machine-id"
    ];
    directories = [
      "/var/db/sudo/lectured"
      "/var/lib/nixos"
      "/var/log/journal"
    ];
  };

  # Impermanence creates parent directories with 0755, but DynamicUser
  # services with StateDirectory require /var/lib/private to be 0700.
  systemd.tmpfiles.rules = [
    "z /var/lib/private 0700 root root -"
  ];
}
