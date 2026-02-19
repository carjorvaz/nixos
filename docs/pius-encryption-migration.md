# Pius Full Disk Encryption Migration Plan

## Goal
Encrypt pius's ZFS pool with Tor hidden service for remote unlock.

## Current State
- `zsafe` pool is unencrypted
- Contains production data (nextcloud, jellyfin, etc.)
- Receives backups from trajanus and hadrianus

## Challenge
ZFS doesn't support in-place encryption. Data must be migrated to new encrypted datasets.

## Migration Options

### Option 1: Internal Migration (needs 2x free space)
1. Create encrypted dataset `zsafe/encrypted`
2. `zfs send zsafe/data | zfs receive zsafe/encrypted/data` for each dataset
3. Destroy old datasets, rename encrypted ones
4. **Risk**: Needs enough free space for duplication

### Option 2: External Disk Migration (safest)
1. Attach temporary external disk
2. Create encrypted pool on external disk
3. `zfs send -R zsafe | zfs receive` to external
4. Swap to external as primary (or send back)
5. **Risk**: Need spare disk, but safest

### Option 3: Network Migration via Backups
1. Ensure trajanus/hadrianus backups are working and complete
2. Back up pius-specific data (nextcloud, configs) to another host
3. Recreate zsafe pool with encryption
4. Restore from backups
5. **Risk**: Depends on backup completeness

## Recommended Approach

**Phase 1: Get backups working first (current task)**
- Fix the raw send encryption issue
- Verify trajanus and hadrianus back up successfully to pius
- This gives us recovery options

**Phase 2: Prepare encryption infrastructure**
- Generate Tor onion service keys
- Generate initrd SSH host key
- Test the zfsRemoteUnlock module (maybe on a VM first)
- Identify network driver for initrd

**Phase 3: Migration**
- Choose migration option based on available resources
- Schedule downtime window
- Execute migration
- Verify and test unlock

## Setup Commands (for Phase 2)

### Generate onion service keys
```bash
nix-shell -p mkp224o --run "mkp224o -n 1 -d ./pius-onion ''"
# Store the folder securely
```

### Generate initrd SSH host key
```bash
ssh-keygen -t ed25519 -N "" -f piusInitrdHostKey
# Optionally encrypt with agenix
```

### Find network driver (on pius)
```bash
lspci -v | grep -A5 -i ethernet
# Look for "Kernel driver in use: <driver>"
```

## Configuration (to add to pius.nix when ready)

```nix
cjv.zfsRemoteUnlock = {
  enable = true;
  authorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
  hostKeyFile = "${self}/secrets/piusInitrdHostKey";
  driver = "<driver>";  # e.g., "r8169", "e1000e", etc.

  static = {
    enable = true;
    address = "192.168.1.1";
    gateway = "192.168.1.254";
    netmask = "255.255.255.0";
    interface = "enp1s0";
  };

  tor = {
    enable = true;
    onionServiceDir = "${self}/secrets/pius-onion";
  };
};
```

## Unlock Command (after migration)
```bash
torify ssh root@<onion-address>.onion
# Then enter ZFS passphrase when prompted
```
