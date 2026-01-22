# ZFS Backup System

Automatic ZFS snapshots and replication using sanoid/syncoid.

## Overview

- **sanoid**: Takes periodic snapshots on source machines
- **syncoid**: Replicates snapshots to backup targets via SSH

## Modules

### sanoid.nix

Base snapshot configuration with a default template:

| Interval   | Retention | Coverage |
|------------|-----------|----------|
| 15 minutes | 4         | 1 hour   |
| Hourly     | 24        | 1 day    |
| Daily      | 7         | 1 week   |
| Weekly     | 4         | 1 month  |
| Monthly    | 12        | 1 year   |
| Yearly     | 2         | 2 years  |

### backupSource.nix

For machines sending backups. Requires a dedicated SSH key (agenix-managed) and declarative known_hosts.

```nix
# Agenix secret for syncoid SSH key
age.secrets.syncoidSshKey = {
  file = "${self}/secrets/syncoidHostnameKey.age";
  owner = "syncoid";
  group = "syncoid";
  mode = "0400";
};

services.zfsBackup.source = {
  enable = true;
  sshKey = config.age.secrets.syncoidSshKey.path;
  targetHosts.pius = "ssh-ed25519 AAAA...";  # pius's host key
  datasets."zroot/safe" = {
    target = "syncoid@pius:zsafe/backups/hostname";
    recursive = true;
  };
};
```

Options:
- `datasets.<name>.target`: Target in format `user@host:pool/dataset`
- `datasets.<name>.recursive`: Replicate child datasets (default: true)
- `datasets.<name>.sendOptions`: ZFS send options (default: "w" for raw/encrypted)
- `datasets.<name>.recvOptions`: ZFS receive options (default: "-o canmount=noauto")
- `targetHosts`: Map of hostname to SSH public key for declarative known_hosts
- `interval`: Replication frequency (default: "hourly")
- `sshKey`: Path to SSH private key (required, typically an agenix secret)
- `noResume`: Disable resumable transfers (default: true). Recommended for roaming devices to avoid stale resume token errors. See [sanoid#304](https://github.com/jimsalterjrs/sanoid/issues/304)

### backupTarget.nix

For machines receiving backups. Creates a syncoid user with limited ZFS permissions.

```nix
services.zfsBackup.target = {
  enable = true;
  sshPublicKeys = [
    "ssh-ed25519 AAAA... syncoid@trajanus"
  ];
};
```

Options:
- `sshPublicKeys`: SSH public keys from source machines' syncoid users
- `dataset`: Backup dataset (default: "zsafe/backups")
- `mountpoint`: Where to mount (default: "/mnt/backups")

Note: Sanoid runs on the target for pruning only (`autosnap = false`). Creating snapshots during active receives causes failures with misleading "kernel modules must be upgraded" errors. See [openzfs/zfs#7024](https://github.com/openzfs/zfs/issues/7024).

## Current Setup

```
trajanus (laptop)
    |
    | zroot/safe -> syncoid@pius:zsafe/backups/trajanus
    v
pius (server)
    zsafe/backups/
        trajanus/
            safe/
                persist/
                ...
```

## Initial Setup

### On the backup target (pius)

1. Deploy the configuration

2. Create the backup dataset:
   ```bash
   zfs create -o mountpoint=/mnt/backups zsafe/backups
   ```

3. Get source machine SSH host keys:
   ```bash
   ssh-keyscan trajanus
   ```

4. Add the ed25519 key to `services.zfsBackup.target.sshPublicKeys` in pius.nix

5. Redeploy

### On backup sources (trajanus, etc.)

1. Generate a dedicated SSH keypair for syncoid:
   ```bash
   ssh-keygen -t ed25519 -f /tmp/syncoid_hostname -N "" -C "syncoid@hostname"
   ```

2. Encrypt the private key with agenix:
   ```bash
   # Add entry to secrets/secrets.nix first, then:
   cd secrets && agenix -e syncoidHostnameKey.age < /tmp/syncoid_hostname
   ```

3. Add the public key to the target's `sshPublicKeys`

4. Get the target's host key for declarative known_hosts:
   ```bash
   ssh-keyscan -t ed25519 pius 2>/dev/null | cut -d' ' -f2-
   ```

5. Configure in host.nix (see backupSource.nix example above)

6. Deploy and test:
   ```bash
   sudo systemctl start syncoid-zroot-safe.service
   journalctl -u syncoid-zroot-safe.service -f
   ```

### Testing the Setup

After deploying both source and target:

1. Verify snapshots are being created:
   ```bash
   # On source (trajanus)
   zfs list -t snapshot -r zroot/safe
   ```

2. Manually trigger a backup:
   ```bash
   # On source (trajanus)
   systemctl start syncoid-zroot-safe
   ```

3. Check the backup was received:
   ```bash
   # On target (pius)
   zfs list -r zsafe/backups
   ls /mnt/backups/trajanus/
   ```

4. Verify automatic replication is scheduled:
   ```bash
   # On source (trajanus)
   systemctl list-timers | grep syncoid
   ```

## Useful Commands

```bash
# List snapshots
zfs list -t snapshot

# List sanoid snapshots for a dataset
zfs list -t snapshot -r zroot/safe

# Check syncoid service status
systemctl status syncoid-zroot-safe

# Manually trigger replication
systemctl start syncoid-zroot-safe

# View syncoid logs
journalctl -u syncoid-zroot-safe

# Mount/unmount backup dataset
zfs mount zsafe/backups
zfs unmount zsafe/backups

# Check ZFS permissions
zfs allow zsafe/backups
```

## Adding More Hosts

### Adding a new backup source

1. Import backupSource.nix in the host config

2. Generate and encrypt a syncoid SSH key (see "On backup sources" above)

3. Add to secrets/secrets.nix:
   ```nix
   "syncoidNewhostKey.age".publicKeys = [ newhostSystem ] ++ users;
   ```

4. Configure the host:
   ```nix
   age.secrets.syncoidSshKey = {
     file = "${self}/secrets/syncoidNewhostKey.age";
     owner = "syncoid";
     group = "syncoid";
     mode = "0400";
   };

   services.zfsBackup.source = {
     enable = true;
     sshKey = config.age.secrets.syncoidSshKey.path;
     targetHosts.pius = "ssh-ed25519 AAAA...";
     datasets."zroot/safe" = {
       target = "syncoid@pius:zsafe/backups/newhostname";
       recursive = true;
     };
   };
   ```

5. Add the syncoid public key to pius's `sshPublicKeys`

### Making pius backup to another host (e.g., julius)

1. On julius, import backupTarget.nix and configure
2. On pius, generate a syncoid key and import backupSource.nix
3. Add pius's syncoid public key to julius's sshPublicKeys

## Accessing Backups

Backup datasets use `canmount=noauto` to avoid mount permission issues.
They must be explicitly mounted before accessing:

```bash
# Mount a specific backup dataset
zfs mount zsafe/backups/trajanus/home

# Mount all backup datasets
zfs mount -a

# List what's mounted
zfs mount | grep backups

# Unmount when done (optional)
zfs unmount zsafe/backups/trajanus/home
```

## Restoring from Backup

To restore a dataset from backup:

```bash
# On the backup target, send to the original host
zfs send -R zsafe/backups/trajanus/safe@autosnap_... | \
  ssh root@trajanus zfs receive -F zroot/safe
```

Or mount the backup and copy files:

```bash
# Mount the backup first
zfs mount zsafe/backups/trajanus/persist

# Copy files
cp /mnt/backups/trajanus/persist/path/to/file /destination/
```
