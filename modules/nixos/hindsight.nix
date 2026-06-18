{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hindsight;

  loopbackBindAddresses = [
    "127.0.0.1"
    "::1"
    "localhost"
  ];
  packageTiktokenCacheDir = cfg.package.tiktokenCacheDir or null;
  packageSupportsLocalOnnx = cfg.package.supportsLocalOnnx or false;
  packageSupportsLocalMl = cfg.package.supportsLocalMl or false;
  effectiveTiktokenCacheDir =
    if packageTiktokenCacheDir != null then packageTiktokenCacheDir else cfg.cacheDir;
  hasOpenAIEmbeddingsSecret = cfg.embeddingsOpenAIApiKeyFile != null;
  hasLLMApiKeySecret = cfg.llmApiKeyFile != null;
  isLoopbackBind = lib.elem cfg.bindAddress loopbackBindAddresses;

  runtimeDirectory = "hindsight";
  credentialsDirectory = "$CREDENTIALS_DIRECTORY";

  toEnvValue = value: if lib.isBool value then lib.boolToString value else toString value;
  toSystemdEnvironmentValue = value: lib.replaceStrings [ "%" ] [ "%%" ] (toEnvValue value);

  plainDatabaseEnvironment = lib.optionalAttrs (cfg.databaseUrl != null) {
    HINDSIGHT_API_DATABASE_URL = cfg.databaseUrl;
  };

  baseEnvironment = {
    HOME = cfg.stateDir;
    XDG_CACHE_HOME = cfg.cacheDir;
    HF_HOME = cfg.cacheDir;
    TIKTOKEN_CACHE_DIR = effectiveTiktokenCacheDir;
    HINDSIGHT_API_HOST = cfg.bindAddress;
    HINDSIGHT_API_PORT = toString cfg.port;
    HINDSIGHT_API_LOG_LEVEL = cfg.logLevel;
    HINDSIGHT_API_LLM_PROVIDER = cfg.llmProvider;
    HINDSIGHT_API_LLM_MODEL = cfg.llmModel;
    HINDSIGHT_API_EMBEDDINGS_PROVIDER = cfg.embeddingsProvider;
  }
  // plainDatabaseEnvironment
  // lib.optionalAttrs (cfg.tenantExtension != null) {
    HINDSIGHT_API_TENANT_EXTENSION = cfg.tenantExtension;
  };

  moduleOwnedEnvironmentKeys = lib.unique (
    lib.attrNames baseEnvironment
    ++ [
      "HINDSIGHT_API_DATABASE_URL"
      "HINDSIGHT_API_LLM_API_KEY"
      "HINDSIGHT_API_TENANT_API_KEY"
      "HINDSIGHT_API_TENANT_EXTENSION"
    ]
    ++ [
      "HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY"
    ]
  );
  overriddenModuleEnvironmentKeys = lib.intersectLists moduleOwnedEnvironmentKeys (
    lib.attrNames cfg.environment
  );
  unownedExtraEnvironment = builtins.removeAttrs cfg.environment moduleOwnedEnvironmentKeys;

  serviceEnvironment = lib.mapAttrs (_: toSystemdEnvironmentValue) (
    lib.filterAttrs (_: value: value != null) (unownedExtraEnvironment // baseEnvironment)
  );

  runtimeSecretEnvFiles = lib.filter (secret: secret.file != null) [
    {
      key = "HINDSIGHT_API_DATABASE_URL";
      file = cfg.databaseUrlFile;
    }
    {
      key = "HINDSIGHT_API_LLM_API_KEY";
      file = cfg.llmApiKeyFile;
    }
    {
      key = "HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY";
      file = cfg.embeddingsOpenAIApiKeyFile;
    }
    {
      key = "HINDSIGHT_API_TENANT_API_KEY";
      file = cfg.tenantApiKeyFile;
    }
  ];

  secretCredentials = map (secret: "${secret.key}:${toString secret.file}") runtimeSecretEnvFiles;

  startScript = pkgs.writeShellScript "hindsight-api-start" (
    ''
      set -eu
    ''
    + lib.concatMapStringsSep "\n" (secret: ''
      value=$(${pkgs.coreutils}/bin/tr -d '\r\n' < "${credentialsDirectory}/${secret.key}")
      export ${secret.key}="$value"
      unset value
    '') runtimeSecretEnvFiles
    + ''
      exec ${lib.getExe cfg.package}
    ''
  );
in
{
  options.services.hindsight = {
    enable = lib.mkEnableOption "Hindsight API service";

    package = lib.mkPackageOption pkgs "hindsight" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "hindsight";
      description = "User account that runs the Hindsight API service.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "hindsight";
      description = "Group account that runs the Hindsight API service.";
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Hindsight API service binds to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8888;
      description = "TCP port the Hindsight API service listens on.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open ports in the firewall for the Hindsight API service.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warning"
        "error"
      ];
      default = "info";
      description = "Hindsight API log level.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hindsight";
      description = "Directory used as HOME and persistent state for Hindsight.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/hindsight";
      description = "Directory used for Hindsight model, tokenizer, and application caches.";
    };

    databaseUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Plain Hindsight API PostgreSQL connection URL for local or passwordless deployments.";
    };

    databaseUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File containing the Hindsight API PostgreSQL connection URL, loaded at runtime through systemd credentials.";
    };

    llmProvider = lib.mkOption {
      type = lib.types.str;
      default = "openai";
      description = "Hindsight API LLM provider name.";
    };

    llmModel = lib.mkOption {
      type = lib.types.str;
      default = "gpt-5-mini";
      description = "Hindsight API LLM model name.";
    };

    llmApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File containing the Hindsight API LLM provider key.";
    };

    embeddingsProvider = lib.mkOption {
      type = lib.types.str;
      default = "openai";
      description = "Hindsight API embeddings provider name.";
    };

    embeddingsOpenAIApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File containing the Hindsight OpenAI embeddings API key, loaded at runtime through systemd credentials.";
    };

    tenantApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File containing the shared tenant API key for Hindsight.";
    };

    tenantExtension = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension";
      description = "Dotted Hindsight tenant extension path, or null to leave tenant auth disabled.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
          lib.types.path
        ]
      );
      default = { };
      description = "Additional environment variables for the Hindsight API service.";
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.tenantApiKeyFile != null) == (cfg.tenantExtension != null);
        message = "services.hindsight.tenantApiKeyFile and services.hindsight.tenantExtension must be set together.";
      }
      {
        assertion = (cfg.databaseUrl != null) != (cfg.databaseUrlFile != null);
        message = "Exactly one of services.hindsight.databaseUrl or services.hindsight.databaseUrlFile must be set.";
      }
      {
        assertion =
          cfg.databaseUrl == null
          || lib.hasPrefix "postgresql://" cfg.databaseUrl
          || lib.hasPrefix "postgres://" cfg.databaseUrl;
        message = "services.hindsight.databaseUrl must be a PostgreSQL URL.";
      }
      {
        assertion = overriddenModuleEnvironmentKeys == [ ];
        message = "services.hindsight.environment must not override module-owned environment keys: ${lib.concatStringsSep ", " overriddenModuleEnvironmentKeys}";
      }
      {
        assertion = cfg.embeddingsProvider != "openai" || hasOpenAIEmbeddingsSecret;
        message = "services.hindsight requires services.hindsight.embeddingsOpenAIApiKeyFile when services.hindsight.embeddingsProvider is openai.";
      }
      {
        assertion = cfg.embeddingsProvider != "onnx" || packageSupportsLocalOnnx;
        message = "services.hindsight.package must be built with local ONNX support when services.hindsight.embeddingsProvider is onnx.";
      }
      {
        assertion = cfg.embeddingsProvider != "local" || packageSupportsLocalMl;
        message = "services.hindsight.package must be built with local ML support when services.hindsight.embeddingsProvider is local.";
      }
      {
        assertion = isLoopbackBind || (cfg.tenantApiKeyFile != null && cfg.tenantExtension != null);
        message = "services.hindsight.tenantApiKeyFile and services.hindsight.tenantExtension must both be set when bindAddress is not loopback.";
      }
      {
        assertion = cfg.llmProvider != "openai" || hasLLMApiKeySecret;
        message = "services.hindsight requires services.hindsight.llmApiKeyFile when services.hindsight.llmProvider is openai.";
      }
    ];

    users.users = lib.mkIf (cfg.user == "hindsight") {
      hindsight = {
        inherit (cfg) group;
        isSystemUser = true;
        home = cfg.stateDir;
      };
    };

    users.groups = lib.mkIf (cfg.group == "hindsight") {
      hindsight = { };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.cacheDir} 0700 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.hindsight = {
      description = "Hindsight API service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [
        cfg.stateDir
        cfg.cacheDir
      ];

      environment = serviceEnvironment;
      path = [
        cfg.package
        pkgs.coreutils
      ];
      serviceConfig = {
        ExecStart =
          if runtimeSecretEnvFiles == [ ] then
            lib.escapeShellArgs [ (lib.getExe cfg.package) ]
          else
            startScript;
        LoadCredential = secretCredentials;
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = runtimeDirectory;
        RuntimeDirectoryMode = "0750";
        StateDirectory = lib.mkIf (cfg.stateDir == "/var/lib/hindsight") "hindsight";
        CacheDirectory = lib.mkIf (cfg.cacheDir == "/var/cache/hindsight") "hindsight";
        WorkingDirectory = cfg.stateDir;
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          cfg.stateDir
          cfg.cacheDir
          "/run/${runtimeDirectory}"
        ];
        BindReadOnlyPaths = [
          "${pkgs.tzdata}/share/zoneinfo:/usr/share/zoneinfo"
        ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        PrivateMounts = true;
        SystemCallArchitectures = "native";
        RestrictNamespaces = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        AmbientCapabilities = [ ];
        CapabilityBoundingSet = [ "" ];
        ProtectProc = "invisible";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        RemoveIPC = true;
        UMask = "0077";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
