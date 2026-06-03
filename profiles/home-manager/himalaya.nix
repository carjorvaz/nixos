{ pkgs, ... }:

{
  # Install the CLI without taking ownership of ~/.config/himalaya/config.toml
  # yet. The Home Manager `programs.himalaya` module generates that file from
  # declarative accounts; defer that until account names and secret commands are
  # settled for air and any future trajanus setup.
  home.packages = [ pkgs.himalaya ];

  xdg.configFile."himalaya/config.toml.example".text = ''
    # Copy to ~/.config/himalaya/config.toml and replace the placeholders.
    # Himalaya is the default for normal IMAP/SMTP mailboxes. For Gmail agent
    # triage, prefer the Gmail API/OAuth path; use the commented Gmail block only
    # if you decide one CLI is more important than native Gmail label semantics.
    #
    # Do not put real passwords in this file. On air, store them in macOS
    # Keychain and reference them with /usr/bin/security. On trajanus, replace
    # the commands with pass/agenix/another local secret command.

    [accounts.normal-1]
    email = "you@example.com"
    display-name = "Carlos Vaz"
    default = true

    backend.type = "imap"
    backend.host = "imap.example.com"
    backend.port = 993
    backend.encryption.type = "tls"
    backend.login = "you@example.com"
    backend.auth.type = "password"
    # security add-generic-password -a you@example.com -s himalaya-normal-1-password -w
    backend.auth.cmd = "/usr/bin/security find-generic-password -a you@example.com -s himalaya-normal-1-password -w"

    message.send.backend.type = "smtp"
    message.send.backend.host = "smtp.example.com"
    message.send.backend.port = 587
    message.send.backend.encryption.type = "start-tls"
    message.send.backend.login = "you@example.com"
    message.send.backend.auth.type = "password"
    message.send.backend.auth.cmd = "/usr/bin/security find-generic-password -a you@example.com -s himalaya-normal-1-password -w"

    folder.aliases.inbox = "INBOX"
    folder.aliases.sent = "Sent"
    folder.aliases.drafts = "Drafts"
    folder.aliases.trash = "Trash"

    # Second normal account template.
    #
    # [accounts.normal-2]
    # email = "you@another-example.com"
    # display-name = "Carlos Vaz"
    #
    # backend.type = "imap"
    # backend.host = "imap.another-example.com"
    # backend.port = 993
    # backend.encryption.type = "tls"
    # backend.login = "you@another-example.com"
    # backend.auth.type = "password"
    # backend.auth.cmd = "/usr/bin/security find-generic-password -a you@another-example.com -s himalaya-normal-2-password -w"
    #
    # message.send.backend.type = "smtp"
    # message.send.backend.host = "smtp.another-example.com"
    # message.send.backend.port = 587
    # message.send.backend.encryption.type = "start-tls"
    # message.send.backend.login = "you@another-example.com"
    # message.send.backend.auth.type = "password"
    # message.send.backend.auth.cmd = "/usr/bin/security find-generic-password -a you@another-example.com -s himalaya-normal-2-password -w"
    #
    # folder.aliases.inbox = "INBOX"
    # folder.aliases.sent = "Sent"
    # folder.aliases.drafts = "Drafts"
    # folder.aliases.trash = "Trash"

    # Optional Gmail-through-Himalaya fallback. This uses Gmail IMAP/SMTP with
    # OAuth2/XOAUTH2. Prefer the Gmail API path for agent triage unless a single
    # CLI matters more than native Gmail labels/search/thread handling.
    #
    # [accounts.gmail]
    # email = "you@gmail.com"
    # display-name = "Carlos Vaz"
    #
    # backend.type = "imap"
    # backend.host = "imap.gmail.com"
    # backend.port = 993
    # backend.encryption.type = "tls"
    # backend.login = "you@gmail.com"
    # backend.auth.type = "oauth2"
    # backend.auth.method = "xoauth2"
    # backend.auth.client-id = "YOUR_DESKTOP_OAUTH_CLIENT_ID.apps.googleusercontent.com"
    # backend.auth.client-secret.keyring = "gmail-oauth2-client-secret"
    # backend.auth.access-token.keyring = "gmail-oauth2-access-token"
    # backend.auth.refresh-token.keyring = "gmail-oauth2-refresh-token"
    # backend.auth.auth-url = "https://accounts.google.com/o/oauth2/v2/auth"
    # backend.auth.token-url = "https://www.googleapis.com/oauth2/v3/token"
    # backend.auth.pkce = true
    # backend.auth.scope = "https://mail.google.com/"
    #
    # message.send.backend.type = "smtp"
    # message.send.backend.host = "smtp.gmail.com"
    # message.send.backend.port = 587
    # message.send.backend.encryption.type = "start-tls"
    # message.send.backend.login = "you@gmail.com"
    # message.send.backend.auth.type = "oauth2"
    # message.send.backend.auth.method = "xoauth2"
    # message.send.backend.auth.client-id = "YOUR_DESKTOP_OAUTH_CLIENT_ID.apps.googleusercontent.com"
    # message.send.backend.auth.client-secret.keyring = "gmail-oauth2-client-secret"
    # message.send.backend.auth.access-token.keyring = "gmail-oauth2-access-token"
    # message.send.backend.auth.refresh-token.keyring = "gmail-oauth2-refresh-token"
    # message.send.backend.auth.auth-url = "https://accounts.google.com/o/oauth2/v2/auth"
    # message.send.backend.auth.token-url = "https://www.googleapis.com/oauth2/v3/token"
    # message.send.backend.auth.pkce = true
    # message.send.backend.auth.scope = "https://mail.google.com/"
    #
    # folder.aliases.inbox = "INBOX"
    # folder.aliases.sent = "[Gmail]/Sent Mail"
    # folder.aliases.drafts = "[Gmail]/Drafts"
    # folder.aliases.trash = "[Gmail]/Trash"
  '';
}
