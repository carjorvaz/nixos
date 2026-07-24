{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  hermesStateDir = "/var/lib/hermes";
  hermesHome = "${hermesStateDir}/.hermes";
  hermesWorkspace = "${hermesStateDir}/workspace";
  nixosMirror = "/home/cjv/sync/nixos";
  simplexStateDir = "${hermesStateDir}/.simplex";
  simplexDbPrefix = "${simplexStateDir}/simplex";
  simplexChatDb = "${simplexDbPrefix}_chat.db";
  simplexFilesDir = "${simplexStateDir}/files";
  simplexTempDir = "${simplexStateDir}/tmp";
  # Hermes 0.17.0 passes numeric contact IDs to SimpleX DM send paths but uses
  # display-name syntax, so replies are silently rejected as "no contact <id>".
  # Use the daemon's structured numeric-ID API until upstream fixes both paths.
  simplexDirectSendOld = ''cmd_str = f"@{chat_id} {content}"'';
  simplexDirectSendNew = ''cmd_str = f"/_send @{chat_id} json {json.dumps([{'msgContent': {'type': 'text', 'text': content}}])}"'';
  simplexStandaloneSendOld = ''cmd_str = f"@{chat_id} {message}"'';
  simplexStandaloneSendNew = ''cmd_str = f"/_send @{chat_id} json {json.dumps([{'msgContent': {'type': 'text', 'text': message}}])}"'';
  simplexPendingFileOld = lib.concatStringsSep "\n" [
    "            # Voice notes typically arrive before the file finishes"
    "            # downloading. Defer the message until rcvFileComplete fires."
    "            if not file_path and _is_audio_ext(ext) and file_id is not None:"
    "                logger.info("
    "                    \"SimpleX: voice file %d not yet received, accepting transfer\","
  ];
  simplexPendingFileNew = lib.concatStringsSep "\n" [
    "            # Attachments can arrive before the file finishes downloading."
    "            # Defer the message until rcvFileComplete supplies its path."
    "            if not file_path and file_id is not None:"
    "                logger.info("
    "                    \"SimpleX: file %d not yet received, accepting transfer\","
  ];
  simplexResolveFileOld = lib.concatStringsSep "\n" [
    "            if file_path:"
    "                ext = Path(file_path).suffix.lower() or ("
  ];
  simplexResolveFileNew = lib.concatStringsSep "\n" [
    "            if file_path:"
    "                path = Path(file_path)"
    "                if not path.is_absolute():"
    "                    files_folder = os.environ.get(\"SIMPLEX_FILES_FOLDER\", \"\")"
    "                    if files_folder:"
    "                        path = Path(files_folder) / path"
    "                file_path = str(path)"
    "                ext = Path(file_path).suffix.lower() or ("
  ];

  hermesMutableConfigHook = pkgs.writeTextDir "${pkgs.python312.sitePackages}/sitecustomize.py" ''
    import os

    if os.environ.get("HERMES_CONFIG_MUTABLE") == "true":
        from hermes_cli import config
        config.get_managed_system = lambda: None
  '';
  # Hermes 0.18.2's TUI imports its local @hermes/shared workspace package,
  # but the upstream Nix source filter omits that package's implementation.
  # Remove this source override once https://github.com/NousResearch/hermes-agent/issues/67056 lands.
  hermesUpstreamPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  hermesUpstreamTui = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.tui;
  hermesTui = hermesUpstreamTui.overrideAttrs (_oldAttrs: {
    src = inputs.hermes-agent;
  });

  hermesPackage =
    let
      package = hermesUpstreamPackage.override {
        extraPythonPackages = [ pkgs.python312Packages.ddgs ];
      };
    in
    package.overrideAttrs (
      oldAttrs:
      let
        oldTuiContext = builtins.getContext "${hermesUpstreamTui}";
        retainedContext = builtins.removeAttrs (builtins.getContext oldAttrs.installPhase) (
          builtins.attrNames oldTuiContext
        );
        replacedInstallPhase =
          builtins.replaceStrings [ "${hermesUpstreamTui}" ] [ "${hermesTui}" ]
            oldAttrs.installPhase;
        installPhase = builtins.appendContext (builtins.unsafeDiscardStringContext replacedInstallPhase) (
          retainedContext // builtins.getContext "${hermesTui}"
        );
      in
      assert installPhase != oldAttrs.installPhase;
      {
        inherit installPhase;
        postInstall = (oldAttrs.postInstall or "") + ''
          pluginsSource="$(${pkgs.coreutils}/bin/readlink -f "$out/share/hermes-agent/plugins")"
          rm "$out/share/hermes-agent/plugins"
          cp -r "$pluginsSource" "$out/share/hermes-agent/plugins"
          chmod -R u+w "$out/share/hermes-agent/plugins"

          substituteInPlace "$out/share/hermes-agent/plugins/platforms/simplex/adapter.py" \
            --replace-fail \
              ${lib.escapeShellArg simplexDirectSendOld} \
              ${lib.escapeShellArg simplexDirectSendNew} \
            --replace-fail \
              ${lib.escapeShellArg simplexStandaloneSendOld} \
              ${lib.escapeShellArg simplexStandaloneSendNew} \
            --replace-fail \
              ${lib.escapeShellArg simplexPendingFileOld} \
              ${lib.escapeShellArg simplexPendingFileNew} \
            --replace-fail \
              ${lib.escapeShellArg simplexResolveFileOld} \
              ${lib.escapeShellArg simplexResolveFileNew}
        '';
      }
    );

  hermesService = pkgs.writeShellApplication {
    name = "hermes-service";
    text = ''
      if [ "''${1:-}" = "update" ] || [ "''${1:-}" = "uninstall" ]; then
        echo "Hermes is managed by NixOS; update the flake input and rebuild instead." >&2
        exit 2
      fi
      # The no-argument TUI stays managed so its /update command cannot mutate
      # the Nix-store package. Only explicit state/configuration managers bypass
      # Hermes's coarse package-manager lock.
      mutable_config=false
      case "''${1:-}" in
        auth|bundles|claw|computer-use|config|cron|curator|fallback|gateway|hooks|import|kanban|login|logout|lsp|mcp|memory|migrate|moa|model|pairing|pets|plugins|portal|profile|project|secrets|setup|skills|slack|tools|whatsapp|whatsapp-cloud)
          mutable_config=true
          ;;
      esac


      if [ "''${1:-}" = "gateway" ]; then
        case "''${2:-}" in
          start|stop|restart)
            exec /run/wrappers/bin/sudo \
              ${pkgs.systemd}/bin/systemctl "$2" hermes-agent.service
            ;;
          install|uninstall)
            echo "The Hermes gateway is managed by NixOS." >&2
            exit 2
            ;;
        esac
      fi

      config_digest() {
        /run/wrappers/bin/sudo -u hermes -- \
          ${pkgs.coreutils}/bin/sha256sum \
            ${lib.escapeShellArg "${hermesHome}/config.yaml"} \
            ${lib.escapeShellArg "${hermesHome}/.env"} \
            2>/dev/null || true
      }

      state_before="$(config_digest)"
      cd ${lib.escapeShellArg hermesWorkspace}
      set +e
      /run/wrappers/bin/sudo -u hermes -- \
        ${pkgs.coreutils}/bin/env \
          HOME=${lib.escapeShellArg hermesStateDir} \
          HERMES_HOME=${lib.escapeShellArg hermesHome} \
          PYTHONPATH=${lib.escapeShellArg "${hermesMutableConfigHook}/${pkgs.python312.sitePackages}"} \
          HERMES_CONFIG_MUTABLE="$mutable_config" \
          ${lib.getExe hermesPackage} "$@"
      status="$?"
      set -e
      state_after="$(config_digest)"

      if [ "$state_before" != "$state_after" ] &&
        ${pkgs.systemd}/bin/systemctl is-active --quiet hermes-agent.service
      then
        /run/wrappers/bin/sudo \
          ${pkgs.systemd}/bin/systemctl restart hermes-agent.service
      fi

      exit "$status"
    '';
  };

  simplexConsole = pkgs.writeShellApplication {
    name = "hermes-simplex-console";
    text = ''
      if [ "$EUID" -ne 0 ]; then
        exec /run/wrappers/bin/sudo "$0" "$@"
      fi

      ${pkgs.coreutils}/bin/install -d \
        -o hermes -g hermes -m 0700 \
        ${lib.escapeShellArg simplexStateDir} \
        ${lib.escapeShellArg simplexFilesDir} \
        ${lib.escapeShellArg simplexTempDir}

      # shellcheck disable=SC2329 # Invoked by the EXIT trap below.
      restore_services() {
        if [ -f ${lib.escapeShellArg simplexChatDb} ]; then
          ${pkgs.systemd}/bin/systemctl start hermes-simplex.service
          if [ -f ${lib.escapeShellArg "${hermesHome}/auth.json"} ]; then
            ${pkgs.systemd}/bin/systemctl start hermes-agent.service
          fi
        fi
      }
      trap restore_services EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM

      ${pkgs.systemd}/bin/systemctl stop \
        hermes-agent.service hermes-simplex.service

      if [ ! -f ${lib.escapeShellArg simplexChatDb} ]; then
        echo "Create the local profile named Hermes, then use /ad to create its contact address."
        echo "Use /quit after copying the address; the 24/7 services will then start."
      fi

      set +e
      ${pkgs.util-linux}/bin/runuser -u hermes -- \
        ${pkgs.coreutils}/bin/env \
          HOME=${lib.escapeShellArg hermesStateDir} \
          ${lib.getExe pkgs.simplex-chat-cli} \
            -y \
            -d ${lib.escapeShellArg simplexDbPrefix} \
            --files-folder ${lib.escapeShellArg simplexFilesDir} \
            --temp-folder ${lib.escapeShellArg simplexTempDir} \
            "$@"
      status="$?"
      set -e


      exit "$status"
    '';
  };
in
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  services.hermes-agent = {
    enable = true;
    package = hermesPackage;
    stateDir = hermesStateDir;
    workingDirectory = hermesWorkspace;
  };

  systemd.tmpfiles.rules = [
    "d ${hermesWorkspace} 2770 hermes hermes -"
    "d ${simplexStateDir} 0700 hermes hermes -"
    "d ${simplexFilesDir} 0700 hermes hermes -"
    "d ${simplexTempDir} 0700 hermes hermes -"
    "a+ /home/cjv - - - - u:hermes:--x,m::--x"
    "A+ /home/cjv/org - - - - u:hermes:rwX"
    "A+ /home/cjv/org - - - - d:u:hermes:rwx"
    "d /home/cjv/sync 0750 cjv users -"
    "a+ /home/cjv/sync - - - - u:hermes:--x,m::--x"
    "d ${nixosMirror} 2770 cjv users -"
    "A+ ${nixosMirror} - - - - u:hermes:rwX,m::rwx"
    "A+ ${nixosMirror} - - - - d:u:hermes:rwx,d:m::rwx"
    "L+ ${hermesWorkspace}/org - - - - /home/cjv/org"
    "L+ ${hermesWorkspace}/nixos - - - - ${nixosMirror}"
  ];

  # users activation reapplies homeMode and can collapse the ACL mask after
  # tmpfiles has run. Reapply these declarative rules after both users and /etc
  # so every switch, not only every boot, preserves Hermes traversal.
  system.activationScripts.hermesWorkspaceAccess = {
    deps = [
      "etc"
      "users"
    ];
    text = ''
      ${pkgs.systemd}/bin/systemd-tmpfiles --create --prefix=/home/cjv
    '';
  };

  environment.persistence."/persist".directories = [
    {
      directory = hermesStateDir;
      user = "hermes";
      group = "hermes";
      mode = "0700";
    }
  ];

  systemd.services = {
    hermes-agent = {
      aliases = [ "hermes-gateway.service" ];
      # Machine-local transport invariants stay declarative. Contact IDs and
      # other private onboarding values live only in the persistent .env.
      environment = {
        SIMPLEX_AUTO_ACCEPT = "false";
        SIMPLEX_WS_URL = "ws://127.0.0.1:5225";
        SIMPLEX_FILES_FOLDER = simplexFilesDir;
      };
      after = [ "hermes-simplex.service" ];
      wants = [ "hermes-simplex.service" ];
      restartTriggers = [ ./hermes.nix ];
      serviceConfig = {
        ReadWritePaths = [
          "/home/cjv/org"
          nixosMirror
        ];
        UnsetEnvironment = [ "MESSAGING_CWD" ];
        TimeoutStopSec = 30;
      };
      unitConfig.ConditionPathExists = [
        "${hermesHome}/auth.json"
        simplexChatDb
      ];
    };

    hermes-simplex = {
      description = "SimpleX transport for Hermes Agent";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathExists = simplexChatDb;
      environment.HOME = hermesStateDir;
      serviceConfig = {
        User = "hermes";
        Group = "hermes";
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs.simplex-chat-cli)
          "-y"
          "-d"
          simplexDbPrefix
          "-p"
          "5225"
          "--files-folder"
          simplexFilesDir
          "--temp-folder"
          simplexTempDir
        ];
        StandardOutput = "null";
        Restart = "always";
        RestartSec = 5;
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          simplexStateDir
        ];
        RestrictSUIDSGID = true;
      };
    };
  };

  environment.systemPackages = [
    hermesService
    simplexConsole
  ];
}
