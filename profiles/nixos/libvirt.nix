{
  config,
  lib,
  pkgs,
  ...
}:

{
  virtualisation = {
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };

  # libvirt's helper unit assumes /usr/bin/sh, which NixOS does not provide.
  systemd.services.virt-secret-init-encryption.serviceConfig.ExecStart = lib.mkForce ''
    ${pkgs.runtimeShell} -c 'umask 0077 && (${pkgs.coreutils}/bin/dd if=/dev/random status=none bs=32 count=1 | ${pkgs.systemd}/bin/systemd-creds encrypt --name=secrets-encryption-key - /var/lib/libvirt/secrets/secrets-encryption-key)'
  '';

  programs.virt-manager.enable = true;
  users.users.cjv.extraGroups = [ "libvirtd" ];

  environment.systemPackages = with pkgs; [ virtiofsd ];

  # libvirt's encrypted key is tied to systemd's host credential secret.
  environment.persistence."/persist" = {
    directories = [ "/var/lib/libvirt" ];
    files = [ "/var/lib/systemd/credential.secret" ];
  };
}
