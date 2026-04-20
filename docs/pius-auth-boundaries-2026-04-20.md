# Pius Auth Boundaries

`pius` now effectively has three auth layers, and they should be chosen
deliberately rather than collapsed into one blanket rule.

1. Tailnet-private reachability
   Services on `vaz.ovh` are intended to live in the private tailnet plane.
   This is the outer network boundary.
2. `nginx.tailscaleAuth`
   This is an HTTP/browser-oriented identity gate layered on top of private
   reachability. It is a great fit for browser-first tools, but awkward for
   native apps and API clients.
3. App-native auth
   This remains the source of truth for apps that actually model users,
   libraries, sessions, playback state, or household/admin roles.

## Steady State

- Browser-first operator tools:
  Tailnet-private reachability plus `nginx.tailscaleAuth`, often with no
  meaningful extra app login.
  Examples: `radarr`, `sonarr`, `bazarr`, `prowlarr`, `transmission`,
  `homer`, `searx`, `pdf-translator`, `jellyseerr`.
- Personal media/library apps:
  Tailnet-private reachability, but keep app-native identity unless the app
  supports a clean SSO or trusted reverse-proxy login path.
  Examples: `audiobookshelf`, `jellyfin`, `home-assistant`.
- Special case:
  `calibre` is tailnet-gated and also auto-logs in cleanly because CWA
  supports trusted reverse-proxy login headers.
- Public/product services:
  Keep separate from the private `vaz.ovh` control plane.
  Examples: `nextcloud`, `ntfy`, `umami`.

## Practical Rule

- Use `nginx.tailscaleAuth` for browser tools.
- Do not put browser-style auth gates in front of native-client-heavy apps
  just to make policy look uniform.
- Keep app-native login where the app's own identity model is still doing real
  work.
