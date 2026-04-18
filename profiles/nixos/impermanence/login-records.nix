{ lib, ... }:
{
  environment.persistence."/persist".files = [
    "/var/log/wtmp"
    "/var/log/btmp"
  ];

  system.activationScripts = {
    # Seed existing login records once so the impermanence bind mount does not
    # fail on non-empty files during the first boot after enabling persistence.
    seedPersistentLoginRecords = {
      deps = [ "createPersistentStorageDirs" ];
      text = ''
        seed_login_record() {
          local file="$1"
          local target="/persist$file"

          if [ -e "$file" ] && [ ! -e "$target" ]; then
            cp -a "$file" "$target"
            : > "$file"
          fi
        }

        seed_login_record /var/log/wtmp
        seed_login_record /var/log/btmp
      '';
    };

    persist-files.deps = lib.mkAfter [ "seedPersistentLoginRecords" ];
  };
}
