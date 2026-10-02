_:

{
  imports = [ ./common.nix ];

  boot.loader.systemd-boot = {
    enable = true;
    editor = false;
    configurationLimit = 8;
  };

  # tiberius (2026-10-02): this box carried a stale firmware variable
  #   LoaderEntryDefault = nixos-generation-47.conf
  # which OVERRIDES loader.conf's `default` in systemd-boot, so every reboot
  # silently went back to generation 47 no matter how many `nixos-rebuild switch`es
  # had activated newer ones.  It was found by cold-booting the v0.1.35 engine
  # rebase: /proc/cmdline pointed at the old system while /run/current-system had
  # been correct before the reboot, and the running engine was the 0.1.29 store
  # path again.  NixOS never manages that variable (it writes only loader.conf,
  # whose `default` it keeps pointing at the newest generation), so the correct
  # state is for the variable to be ABSENT.  It was cleared with
  # `bootctl set-default ""`; plain `bootctl set-default` (no argument) is refused
  # by this version, and `rm` / an empty write on the efivarfs file fail with EPERM
  # on this firmware.  If a boot ever lands on an old generation again, read
  # /sys/firmware/efi/efivars/LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
  # first, and re-run the boot test after any `nixos-rebuild` that matters.
}
