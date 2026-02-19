# Secrets

Uses agenix. SSH keys for encryption/decryption.

## Adding a secret

1. Add to `secrets.nix`:
   ```nix
   "mySecret.age".publicKeys = [
     piusSystem
   ] ++ users;
   ```

2. Create it:
   ```bash
   cd secrets
   agenix -e mySecret.age
   ```

## Editing a secret

```bash
cd secrets
agenix -e secretName.age
```

## Re-keying (after changing keys in secrets.nix)

```bash
cd secrets
agenix -r
```

## Getting a new system's public key

```bash
ssh root@host cat /persist/etc/ssh/ssh_host_ed25519_key.pub
```
