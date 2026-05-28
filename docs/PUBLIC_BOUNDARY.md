# Public Boundary

This repository is public infrastructure-as-code. Treat every committed file, public CI log, and copied command output as potentially visible to the internet.

## Allowed by default

- NixOS, nix-darwin, Home Manager, package, module, and profile code.
- Encrypted agenix files (`*.age`) registered through `secrets/secrets.nix`.
- Public keys, host names, public service names, and non-sensitive routing intent that the repo intentionally models.
- Redacted examples and deterministic test fixtures.
- Public-safe validation commands that do not contact private hosts or decrypt secrets.

## Do not commit

- Plaintext `.env` files, tokens, passwords, API keys, cookies, private keys, or decrypted secret material.
- Raw service logs, copied shell transcripts, screenshots, crash dumps, or API responses that may contain credentials, account data, private URLs, or request bodies.
- Live incident notes, exact private operational state, or detailed private topology that is not already intentionally modeled in the repo.
- Generated build artifacts, VM images, caches, database dumps, downloaded APKs, media captures, or other bulky/runtime outputs unless the repo explicitly tracks them.

## CI and automation boundary

Do not add public GitHub Actions or other public CI that:

- SSHes to hosts;
- deploys, switches, reboots, or unlocks systems;
- decrypts agenix secrets;
- requires private credentials;
- prints full evaluated configuration for real hosts;
- publishes logs from private services or tailscale-only endpoints.

Prefer local validation first. If CI is added later, keep the initial scope to public-safe checks such as formatting, docs invariants, package evaluation, or dry-run builds that cannot expose secrets.

## Review checklist for agents

Before reporting a change ready in this repo:

1. Check `git diff --check HEAD --` or run `scripts/validate`.
2. Inspect new files for accidental secrets, logs, transcripts, and bulky generated artifacts.
3. Keep reusable modules generic; move host/domain/dashboard exposure to profiles or hosts.
4. Avoid adding deploy, SSH, or secret-decryption behavior to default validation or public CI.
5. If a new rule prevented a mistake, consider encoding it in `checks/` or `scripts/validate` instead of only documenting it.
