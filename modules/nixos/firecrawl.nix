{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.firecrawl;

  redisUnit =
    if cfg.redis.serverName == "" then
      "redis.service"
    else
      "redis-${cfg.redis.serverName}.service";

  redisUrl =
    if cfg.redis.url != null then
      cfg.redis.url
    else
      "redis://${cfg.redis.bind}:${toString cfg.redis.port}";

  postgresqlUrl =
    if cfg.postgresql.url != null then
      cfg.postgresql.url
    else
      "postgresql://${cfg.postgresql.user}@${cfg.postgresql.bind}:${toString cfg.postgresql.port}/${cfg.postgresql.database}";

  rabbitmqUrl =
    if cfg.rabbitmq.url != null then
      cfg.rabbitmq.url
    else
      "amqp://${cfg.rabbitmq.bind}:${toString cfg.rabbitmq.port}";

  postgresqlUnit = "postgresql.service";
  postgresqlSetupUnit = "postgresql-setup.service";
  rabbitmqUnit = "rabbitmq.service";
  nuqInitUnit = "firecrawl-nuq-init.service";

  dependencyUnits =
    lib.optional cfg.redis.enable redisUnit
    ++ lib.optional cfg.rabbitmq.enable rabbitmqUnit
    ++ lib.optionals cfg.postgresql.enable [
      postgresqlUnit
      postgresqlSetupUnit
    ]
    ++ lib.optional cfg.postgresql.enable nuqInitUnit;

  psql = "${config.services.postgresql.package}/bin/psql";
  nuqInitScript = pkgs.writeShellScript "firecrawl-nuq-init" ''
    set -euo pipefail

    ${psql} -v ON_ERROR_STOP=1 -d ${lib.escapeShellArg cfg.postgresql.database} -f ${./firecrawl-nuq-schema.sql}
    ${psql} -v ON_ERROR_STOP=1 -d ${lib.escapeShellArg cfg.postgresql.database} <<'SQL'
    GRANT USAGE ON SCHEMA nuq TO "${cfg.postgresql.user}";
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA nuq TO "${cfg.postgresql.user}";
    GRANT USAGE ON TYPE nuq.job_status TO "${cfg.postgresql.user}";
    GRANT USAGE ON TYPE nuq.group_status TO "${cfg.postgresql.user}";
    SQL
  '';

  toEnvValue = value:
    if lib.isBool value then
      lib.boolToString value
    else
      toString value;

  baseEnvironment = {
    HOST = cfg.bindAddress;
    PORT = cfg.port;
    ENV = "local";
    IS_PRODUCTION = true;

    # Keep the private instance simple: Tailscale/nginx protects access, so do
    # not require Firecrawl's Supabase-backed API-key machinery.
    USE_DB_AUTHENTICATION = false;

    REDIS_URL = redisUrl;
    REDIS_RATE_LIMIT_URL = redisUrl;

    POSTGRES_HOST = cfg.postgresql.bind;
    POSTGRES_PORT = cfg.postgresql.port;
    POSTGRES_DB = cfg.postgresql.database;
    POSTGRES_USER = cfg.postgresql.user;
    NUQ_DATABASE_URL = postgresqlUrl;
    NUQ_DATABASE_URL_LISTEN = postgresqlUrl;
    NUQ_RABBITMQ_URL = rabbitmqUrl;

    WORKER_PORT = cfg.workerPort;
    EXTRACT_WORKER_PORT = cfg.extractWorkerPort;
    NUQ_WORKER_COUNT = cfg.nuqWorkerCount;

    DISABLE_WEBHOOK_DELIVERY = true;
    LOGGING_LEVEL = cfg.logLevel;
  }
  // lib.optionalAttrs (cfg.playwrightMicroserviceUrl != null) {
    PLAYWRIGHT_MICROSERVICE_URL = cfg.playwrightMicroserviceUrl;
  }
  // lib.optionalAttrs (cfg.publicUrl != null) {
    FIRECRAWL_APP_SCHEME = "https";
    FIRECRAWL_APP_HOST = cfg.publicUrl;
    FIRECRAWL_APP_PORT = "443";
  };

  serviceEnvironment = lib.mapAttrs (_: toEnvValue) (
    lib.filterAttrs (_: value: value != null) (baseEnvironment // cfg.environment)
  );

  serviceConfig = {
    User = cfg.user;
    Group = cfg.group;
    StateDirectory = "firecrawl";
    CacheDirectory = "firecrawl";
    RuntimeDirectory = "firecrawl";
    UMask = "0077";
    Restart = "on-failure";
    RestartSec = "5s";

    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
  }
  // lib.optionalAttrs (cfg.environmentFile != null) {
    EnvironmentFile = cfg.environmentFile;
  };

  mkFirecrawlService =
    {
      description,
      executable,
      extraEnvironment ? { },
    }:
    {
      inherit description;
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ] ++ dependencyUnits;
      wants = dependencyUnits;
      requires = lib.optional cfg.postgresql.enable nuqInitUnit;
      environment = serviceEnvironment // lib.mapAttrs (_: toEnvValue) extraEnvironment;
      serviceConfig = serviceConfig // {
        ExecStart = "${cfg.package}/bin/${executable}";
      };
    };
in
{
  options.services.firecrawl = {
    enable = lib.mkEnableOption "Firecrawl private extraction service";

    package = lib.mkPackageOption pkgs "firecrawl" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "firecrawl";
      description = "User account running the Firecrawl services.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "firecrawl";
      description = "Group account running the Firecrawl services.";
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Firecrawl API server binds to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3002;
      description = "Firecrawl API server port.";
    };

    workerPort = lib.mkOption {
      type = lib.types.port;
      default = 3005;
      description = "Internal queue-worker liveness port.";
    };

    extractWorkerPort = lib.mkOption {
      type = lib.types.port;
      default = 3004;
      description = "Internal extract-worker liveness port.";
    };

    nuqWorkerCount = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Number of NUQ workers advertised to Firecrawl when started outside the upstream harness.";
    };

    logLevel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "info";
      description = "Firecrawl LOGGING_LEVEL value.";
    };

    publicUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public/private DNS name for FIRECRAWL_APP_* environment values.";
    };

    playwrightMicroserviceUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Firecrawl Playwright microservice URL.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.path
          lib.types.port
          lib.types.int
          lib.types.bool
        ]
      );
      default = { };
      description = "Additional Firecrawl environment variables. Values override module defaults.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional systemd EnvironmentFile for secrets such as upstream API keys.";
    };

    postgresql = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to create a local PostgreSQL NUQ database for Firecrawl.";
      };

      database = lib.mkOption {
        type = lib.types.str;
        default = "firecrawl";
        description = "PostgreSQL database used by Firecrawl NUQ queues.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "firecrawl";
        description = "PostgreSQL user used by Firecrawl NUQ queues.";
      };

      bind = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "PostgreSQL bind address used when postgresql.url is not set.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "PostgreSQL TCP port used when postgresql.url is not set.";
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External NUQ PostgreSQL connection URL. When set, Firecrawl uses this and the local PostgreSQL setup may be disabled.";
      };
    };

    rabbitmq = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run a local RabbitMQ instance for Firecrawl NUQ/extract queues.";
      };

      bind = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "RabbitMQ bind address used when rabbitmq.url is not set.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5672;
        description = "RabbitMQ AMQP port used when rabbitmq.url is not set.";
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External RabbitMQ AMQP URL. When set, Firecrawl uses this and the local RabbitMQ server may be disabled.";
      };
    };

    redis = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run a local Redis instance for Firecrawl queues and rate limits.";
      };

      serverName = lib.mkOption {
        type = lib.types.str;
        default = "firecrawl";
        description = "Name of the NixOS Redis server instance.";
      };

      bind = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Redis bind address used when redis.url is not set.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 6380;
        description = "Redis TCP port used when redis.url is not set.";
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External Redis URL. When set, Firecrawl uses this and the local Redis server may be disabled.";
      };
    };

    nginx = {
      enable = lib.mkEnableOption "nginx reverse proxy for Firecrawl";

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Virtual host name for the nginx reverse proxy.";
      };

      useACMEHost = lib.mkOption {
        type = lib.types.str;
        default = "vaz.ovh";
        description = "ACME certificate name for the nginx virtual host.";
      };

      tailscaleAuth = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Protect the nginx virtual host with Tailscale auth headers.";
      };
    };

    homer = {
      enable = lib.mkEnableOption "Homer dashboard entry for Firecrawl";

      name = lib.mkOption {
        type = lib.types.str;
        default = "Firecrawl";
        description = "Homer entry display name.";
      };

      subtitle = lib.mkOption {
        type = lib.types.str;
        default = "Web extraction";
        description = "Homer entry subtitle.";
      };

      logo = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Homer entry logo path. Empty string omits the logo.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "ai";
        description = "Homer dashboard group.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.nginx.enable || cfg.nginx.domain != null;
        message = "services.firecrawl.nginx.domain must be set when services.firecrawl.nginx.enable is true.";
      }
      {
        assertion = cfg.redis.enable || cfg.redis.url != null;
        message = "services.firecrawl.redis.url must be set when the local Firecrawl Redis server is disabled.";
      }
      {
        assertion = cfg.postgresql.enable || cfg.postgresql.url != null;
        message = "services.firecrawl.postgresql.url must be set when the local Firecrawl PostgreSQL setup is disabled.";
      }
      {
        assertion = cfg.rabbitmq.enable || cfg.rabbitmq.url != null;
        message = "services.firecrawl.rabbitmq.url must be set when the local Firecrawl RabbitMQ server is disabled.";
      }
      {
        assertion = !cfg.homer.enable || cfg.nginx.domain != null;
        message = "services.firecrawl.nginx.domain must be set when services.firecrawl.homer.enable is true.";
      }
    ];

    users = {
      users.${cfg.user} = {
        inherit (cfg) group;
        isSystemUser = true;
      };
      groups.${cfg.group} = { };
    };

    services.redis.servers = lib.mkIf cfg.redis.enable {
      ${cfg.redis.serverName} = {
        enable = true;
        bind = cfg.redis.bind;
        port = cfg.redis.port;
        openFirewall = false;
        save = [ ];
        appendOnly = false;
      };
    };

    services.rabbitmq = lib.mkIf cfg.rabbitmq.enable {
      enable = true;
      listenAddress = cfg.rabbitmq.bind;
      port = cfg.rabbitmq.port;
    };

    services.postgresql = lib.mkIf cfg.postgresql.enable {
      enable = true;
      enableTCPIP = true;
      ensureDatabases = [ cfg.postgresql.database ];
      ensureUsers = [
        {
          name = cfg.postgresql.user;
          ensureDBOwnership = true;
        }
      ];

      # Firecrawl's node-postgres client connects over TCP. Prepend a narrow
      # trust rule for this local DB/user pair so existing local services keep
      # their generated authentication behavior.
      authentication = lib.mkBefore ''
        host ${cfg.postgresql.database} ${cfg.postgresql.user} ${cfg.postgresql.bind}/32 trust
      '';
    };

    systemd.services = {
      firecrawl-nuq-init = lib.mkIf cfg.postgresql.enable {
        description = "Initialize Firecrawl NUQ PostgreSQL schema";
        after = [
          postgresqlUnit
          postgresqlSetupUnit
        ];
        requires = [
          postgresqlUnit
          postgresqlSetupUnit
        ];
        before = [
          "firecrawl-api.service"
          "firecrawl-worker.service"
          "firecrawl-extract-worker.service"
        ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          ExecStart = nuqInitScript;
          RemainAfterExit = true;
        };
      };

      firecrawl-api = mkFirecrawlService {
        description = "Firecrawl API server";
        executable = "firecrawl-api";
        extraEnvironment.NUQ_POD_NAME = "api";
      };

      firecrawl-worker = mkFirecrawlService {
        description = "Firecrawl queue worker";
        executable = "firecrawl-worker";
        extraEnvironment.NUQ_POD_NAME = "worker";
      };

      firecrawl-extract-worker = mkFirecrawlService {
        description = "Firecrawl extract worker";
        executable = "firecrawl-extract-worker";
        extraEnvironment.NUQ_POD_NAME = "extract-worker";
      };
    };

    services.nginx = lib.mkIf cfg.nginx.enable {
      tailscaleAuth = lib.mkIf cfg.nginx.tailscaleAuth {
        enable = true;
        virtualHosts = [ cfg.nginx.domain ];
      };

      virtualHosts.${cfg.nginx.domain} = {
        forceSSL = true;
        useACMEHost = cfg.nginx.useACMEHost;
        locations."/" = {
          proxyPass = "http://${cfg.bindAddress}:${toString cfg.port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_connect_timeout 30s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
          '';
        };
      };
    };

    services.homer.entries = lib.mkIf cfg.homer.enable [
      {
        name = cfg.homer.name;
        subtitle = cfg.homer.subtitle;
        url = "https://${cfg.nginx.domain}";
        logo = cfg.homer.logo;
        group = cfg.homer.group;
      }
    ];
  };
}
