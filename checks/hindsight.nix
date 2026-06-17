{
  lib,
  pkgs,
}:

let
  hindsightModule = ../modules/nixos/hindsight.nix;
  tenantExtension = "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension";
  expectedLocalDatabaseUrl = "postgresql://hindsight@127.0.0.1:5432/hindsight";
  expectedTiktokenCacheDir = pkgs.hindsight.tiktokenCacheDir or null;
  expectedRuntimeDefaults = {
    requiresDatabaseUrl = true;
    embeddingsProvider = "openai";
    embeddingsOpenAIModel = "text-embedding-3-small";
    rerankerProvider = "rrf";
  };
  packageRuntimeDefaults = pkgs.hindsight.passthru.runtimeDefaults or null;

  mkHindsightConfig =
    hindsightConfig:
    lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        hindsightModule
        {
          nixpkgs.pkgs = pkgs;
          services.hindsight = {
            enable = true;
            package = pkgs.hindsight;
            databaseUrl = expectedLocalDatabaseUrl;
            embeddingsOpenAIApiKeyFile = "/run/keys/hindsight-embeddings-openai";
          }
          // hindsightConfig;
          system.stateVersion = "25.11";
        }
      ];
    };

  mkHindsightAssertionConfig =
    hindsightConfig:
    lib.evalModules {
      specialArgs = {
        inherit pkgs;
      };
      modules = [
        hindsightModule
        (
          { lib, ... }:
          {
            options = {
              assertions = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      assertion = lib.mkOption {
                        type = lib.types.bool;
                      };
                      message = lib.mkOption {
                        type = lib.types.str;
                      };
                    };
                  }
                );
                default = [ ];
              };
              users.users = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              users.groups = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              systemd.tmpfiles.rules = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
              systemd.services = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
            };
            config.services.hindsight = {
              enable = true;
              package = pkgs.hindsight;
              databaseUrl = expectedLocalDatabaseUrl;
              embeddingsOpenAIApiKeyFile = "/run/keys/hindsight-embeddings-openai";
            }
            // hindsightConfig;
          }
        )
      ];
    };

  minimalConfig = mkHindsightConfig { };

  configuredConfig = mkHindsightConfig {
    bindAddress = "127.0.0.1";
    port = 8890;
    logLevel = "debug";
    stateDir = "/var/lib/hindsight-check";
    cacheDir = "/var/cache/hindsight-check";
    databaseUrl = null;
    databaseUrlFile = "/run/keys/hindsight-database-url";
    llmProvider = "none";
    embeddingsProvider = "openai";
    embeddingsOpenAIApiKeyFile = "/run/keys/hindsight-embeddings-openai";
    llmModel = "unused";
    llmApiKeyFile = "/run/keys/hindsight-llm";
    tenantApiKeyFile = "/run/keys/hindsight-tenant";
    tenantExtension = tenantExtension;
    environment = {
      HINDSIGHT_API_WORKER_ID = "nixos-check";
      HINDSIGHT_API_STORE_DOCUMENT_TEXT = false;
      HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL = "text-embedding-3-small";
      HINDSIGHT_API_RERANKER_PROVIDER = "rrf";
    };
  };
  databaseUrlFileConfig = mkHindsightConfig {
    databaseUrl = null;
    databaseUrlFile = "/run/keys/hindsight-database-url";
    llmApiKeyFile = "/run/keys/hindsight-llm";
    embeddingsOpenAIApiKeyFile = "/run/keys/hindsight-embeddings-openai";
    tenantApiKeyFile = "/run/keys/hindsight-tenant";
    tenantExtension = tenantExtension;
  };

  hindsightAssertion =
    expectedMessage: missingMessage: hindsightConfig:
    let
      matchingAssertions = lib.filter (assertion: assertion.message == expectedMessage) (
        (mkHindsightAssertionConfig hindsightConfig).config.assertions
      );
    in
    if matchingAssertions == [ ] then throw missingMessage else (lib.head matchingAssertions).assertion;
  moduleOwnedEnvironmentOverrideEval = builtins.tryEval (
    let
      matchingAssertions =
        lib.filter
          (
            assertion:
            lib.hasPrefix "services.hindsight.environment must not override module-owned environment keys:" assertion.message
          )
          (
            (mkHindsightAssertionConfig {
              environment = {
                HINDSIGHT_API_HOST = "0.0.0.0";
                HINDSIGHT_API_DATABASE_URL = "postgresql://override.invalid/hindsight";
                HINDSIGHT_API_TENANT_API_KEY = "unsafe-bypass";
                HINDSIGHT_API_TENANT_EXTENSION = "unsafe.extension:Tenant";
                HINDSIGHT_API_EMBEDDINGS_PROVIDER = "local";
                HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY = "unsafe-bypass";
              };
            }).config.assertions
          );
    in
    if matchingAssertions == [ ] then
      throw "Hindsight module-owned environment override assertion was not registered."
    else
      (lib.head matchingAssertions).assertion
  );

  hindsightTenantPairAssertion = hindsightAssertion "services.hindsight.tenantApiKeyFile and services.hindsight.tenantExtension must be set together." "Hindsight tenant pair assertion was not registered.";

  hindsightNonLoopbackTenantAssertion = hindsightAssertion "services.hindsight.tenantApiKeyFile and services.hindsight.tenantExtension must both be set when bindAddress is not loopback." "Hindsight non-loopback tenant assertion was not registered.";
  hindsightOpenAIEmbeddingsSecretAssertion = hindsightAssertion "services.hindsight requires services.hindsight.embeddingsOpenAIApiKeyFile when services.hindsight.embeddingsProvider is openai." "Hindsight OpenAI embeddings secret assertion was not registered.";

  openAIEmbeddingsWithoutSecretEval = builtins.tryEval (hindsightOpenAIEmbeddingsSecretAssertion {
    embeddingsOpenAIApiKeyFile = null;
  });

  openAIEmbeddingsWithCredentialSecretEval =
    builtins.tryEval
      (hindsightOpenAIEmbeddingsSecretAssertion {
        embeddingsOpenAIApiKeyFile = "/run/keys/hindsight-embeddings-openai";
      });

  openAIEmbeddingsWithOnlyLlmSecretEval = builtins.tryEval (hindsightOpenAIEmbeddingsSecretAssertion {
    embeddingsOpenAIApiKeyFile = null;
    llmApiKeyFile = "/run/keys/hindsight-llm";
  });

  nonOpenAIEmbeddingsWithoutSecretEval = builtins.tryEval (hindsightOpenAIEmbeddingsSecretAssertion {
    embeddingsProvider = "local";
    embeddingsOpenAIApiKeyFile = null;
  });

  loopbackTenantApiKeyWithoutExtensionEval = builtins.tryEval (hindsightTenantPairAssertion {
    tenantApiKeyFile = "/run/keys/hindsight-tenant";
  });

  loopbackTenantExtensionWithoutApiKeyEval = builtins.tryEval (hindsightTenantPairAssertion {
    tenantExtension = tenantExtension;
  });

  loopbackWithoutTenantAuthEval = builtins.tryEval (hindsightTenantPairAssertion { });

  loopbackWithTenantAuthEval = builtins.tryEval (hindsightTenantPairAssertion {
    tenantApiKeyFile = "/run/keys/hindsight-tenant";
    tenantExtension = tenantExtension;
  });

  unsafeBindWithoutTenantApiKeyEval = builtins.tryEval (hindsightNonLoopbackTenantAssertion {
    bindAddress = "0.0.0.0";
    tenantExtension = tenantExtension;
  });

  unsafeBindWithoutTenantExtensionEval = builtins.tryEval (hindsightNonLoopbackTenantAssertion {
    bindAddress = "0.0.0.0";
    tenantApiKeyFile = "/run/keys/hindsight-tenant";
  });

  safeNonLoopbackBindEval = builtins.tryEval (hindsightNonLoopbackTenantAssertion {
    bindAddress = "0.0.0.0";
    tenantApiKeyFile = "/run/keys/hindsight-tenant";
    tenantExtension = tenantExtension;
  });

  minimalService = minimalConfig.config.systemd.services.hindsight;
  databaseUrlFileService = databaseUrlFileConfig.config.systemd.services.hindsight;
  configuredService = configuredConfig.config.systemd.services.hindsight;
  configuredPostgresql = configuredConfig.config.services.postgresql;

  minimalEnvironmentFile = minimalService.serviceConfig.EnvironmentFile or [ ];
  configuredEnvironmentFile = configuredService.serviceConfig.EnvironmentFile or [ ];
  databaseUrlFileEnvironmentFile = databaseUrlFileService.serviceConfig.EnvironmentFile or [ ];
  expectedMinimalLoadCredential = [
    "HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY:/run/keys/hindsight-embeddings-openai"
  ];
  expectedConfiguredLoadCredential = [
    "HINDSIGHT_API_DATABASE_URL:/run/keys/hindsight-database-url"
    "HINDSIGHT_API_LLM_API_KEY:/run/keys/hindsight-llm"
    "HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY:/run/keys/hindsight-embeddings-openai"
    "HINDSIGHT_API_TENANT_API_KEY:/run/keys/hindsight-tenant"
  ];
  expectedDatabaseUrlFileLoadCredential = [
    "HINDSIGHT_API_DATABASE_URL:/run/keys/hindsight-database-url"
    "HINDSIGHT_API_LLM_API_KEY:/run/keys/hindsight-llm"
    "HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY:/run/keys/hindsight-embeddings-openai"
    "HINDSIGHT_API_TENANT_API_KEY:/run/keys/hindsight-tenant"
  ];
in
{
  hindsight-module-generic-quality = pkgs.runCommand "hindsight-module-generic-quality" { } ''
    forbidden='services\.homer|homer\.|services\.nginx|nginx\.|useACMEHost|vaz\.ovh|\bpius\b|/persist|age\.secrets|agenix|pg0|pg0-embedded|postgresql_[0-9]+|withPackages|services\.postgresql|hindsight-vector-init|services\.hindsight\.postgresql'

    if grep -nE "$forbidden" ${hindsightModule}; then
      echo "Hindsight module still contains private profile concerns, PostgreSQL ownership, or embedded pg0 wiring." >&2
      echo "Keep host/domain/nginx/ACME/Homer/persistence/secret/PostgreSQL declarations in profiles or fixtures; the generic module only accepts databaseUrl or databaseUrlFile." >&2
      exit 1
    fi

    module_footguns='environmentFile|extraArgs|EnvironmentFile|write_secret_env'

    if grep -nE "$module_footguns" ${hindsightModule}; then
      echo "Hindsight module still exposes EnvironmentFile/extraArgs override paths or generated secret EnvironmentFile handling." >&2
      exit 1
    fi

    touch $out
  '';

  hindsight-unsafe-bind-rejected = pkgs.runCommand "hindsight-unsafe-bind-rejected" { } ''
    if [ "${lib.boolToString unsafeBindWithoutTenantApiKeyEval.success}" != true ]; then
      echo "Could not evaluate Hindsight non-loopback tenant assertion without tenantApiKeyFile." >&2
      exit 1
    fi

    if [ "${lib.boolToString unsafeBindWithoutTenantApiKeyEval.value}" != false ]; then
      echo "Hindsight must reject non-loopback binds without tenantApiKeyFile." >&2
      exit 1
    fi

    if [ "${lib.boolToString unsafeBindWithoutTenantExtensionEval.success}" != true ]; then
      echo "Could not evaluate Hindsight non-loopback tenant assertion without tenantExtension." >&2
      exit 1
    fi

    if [ "${lib.boolToString unsafeBindWithoutTenantExtensionEval.value}" != false ]; then
      echo "Hindsight must reject non-loopback binds without tenantExtension." >&2
      exit 1
    fi

    if [ "${lib.boolToString safeNonLoopbackBindEval.success}" != true ]; then
      echo "Could not evaluate Hindsight non-loopback tenant assertion with tenantApiKeyFile and tenantExtension." >&2
      exit 1
    fi

    if [ "${lib.boolToString safeNonLoopbackBindEval.value}" != true ]; then
      echo "Hindsight must accept non-loopback binds when tenantApiKeyFile and tenantExtension are both set." >&2
      exit 1
    fi

    touch $out
  '';

  hindsight-tenant-pair-rejected = pkgs.runCommand "hindsight-tenant-pair-rejected" { } ''
    if [ "${lib.boolToString loopbackTenantApiKeyWithoutExtensionEval.success}" != true ]; then
      echo "Could not evaluate Hindsight tenant pair assertion without tenantExtension." >&2
      exit 1
    fi

    if [ "${lib.boolToString loopbackTenantApiKeyWithoutExtensionEval.value}" != false ]; then
      echo "Hindsight must reject tenantApiKeyFile without tenantExtension." >&2
      exit 1
    fi

    if [ "${lib.boolToString loopbackTenantExtensionWithoutApiKeyEval.success}" != true ]; then
      echo "Could not evaluate Hindsight tenant pair assertion without tenantApiKeyFile." >&2
      exit 1
    fi

    if [ "${lib.boolToString loopbackTenantExtensionWithoutApiKeyEval.value}" != false ]; then
      echo "Hindsight must reject tenantExtension without tenantApiKeyFile." >&2
      exit 1
    fi

    if [ "${lib.boolToString loopbackWithoutTenantAuthEval.success}" != true ]; then
      echo "Could not evaluate Hindsight tenant pair assertion without tenant auth." >&2
      exit 1
    fi

    if [ "${lib.boolToString loopbackWithoutTenantAuthEval.value}" != true ]; then
      echo "Hindsight must accept loopback binds without tenant auth." >&2
      exit 1
    fi

    if [ "${lib.boolToString loopbackWithTenantAuthEval.success}" != true ]; then
      echo "Could not evaluate Hindsight tenant pair assertion with tenantApiKeyFile and tenantExtension." >&2
      exit 1
    fi

    if [ "${lib.boolToString loopbackWithTenantAuthEval.value}" != true ]; then
      echo "Hindsight must accept tenantApiKeyFile and tenantExtension when both are set." >&2
      exit 1
    fi

    touch $out
  '';

  hindsight-owned-environment-rejected = pkgs.runCommand "hindsight-owned-environment-rejected" { } ''
    if [ "${lib.boolToString moduleOwnedEnvironmentOverrideEval.success}" != true ]; then
      echo "Could not evaluate Hindsight module-owned environment override assertion." >&2
      exit 1
    fi

    if [ "${lib.boolToString moduleOwnedEnvironmentOverrideEval.value}" != false ]; then
      echo "Hindsight must reject services.hindsight.environment overrides for module-owned keys." >&2
      exit 1
    fi

    touch $out
  '';

  hindsight-openai-embeddings-secret-rejected =
    pkgs.runCommand "hindsight-openai-embeddings-secret-rejected" { }
      ''
        if [ "${lib.boolToString openAIEmbeddingsWithoutSecretEval.success}" != true ]; then
          echo "Could not evaluate Hindsight OpenAI embeddings secret assertion without a secret source." >&2
          exit 1
        fi

        if [ "${lib.boolToString openAIEmbeddingsWithoutSecretEval.value}" != false ]; then
          echo "Hindsight must reject OpenAI embeddings without embeddingsOpenAIApiKeyFile." >&2
          exit 1
        fi

        if [ "${lib.boolToString openAIEmbeddingsWithCredentialSecretEval.success}" != true ]; then
          echo "Could not evaluate Hindsight OpenAI embeddings secret assertion with embeddingsOpenAIApiKeyFile." >&2
          exit 1
        fi

        if [ "${lib.boolToString openAIEmbeddingsWithCredentialSecretEval.value}" != true ]; then
          echo "Hindsight must accept OpenAI embeddings when embeddingsOpenAIApiKeyFile is set." >&2
          exit 1
        fi

        if [ "${lib.boolToString openAIEmbeddingsWithOnlyLlmSecretEval.success}" != true ]; then
          echo "Could not evaluate Hindsight OpenAI embeddings secret assertion with only llmApiKeyFile." >&2
          exit 1
        fi

        if [ "${lib.boolToString openAIEmbeddingsWithOnlyLlmSecretEval.value}" != false ]; then
          echo "Hindsight must not treat llmApiKeyFile as satisfying the OpenAI embeddings secret." >&2
          exit 1
        fi


        if [ "${lib.boolToString nonOpenAIEmbeddingsWithoutSecretEval.success}" != true ]; then
          echo "Could not evaluate Hindsight embeddings secret assertion with a non-OpenAI provider." >&2
          exit 1
        fi

        if [ "${lib.boolToString nonOpenAIEmbeddingsWithoutSecretEval.value}" != true ]; then
          echo "Hindsight must allow non-OpenAI embeddings providers without an OpenAI secret source." >&2
          exit 1
        fi

        touch $out
      '';

  hindsight-module-eval = pkgs.runCommand "hindsight-module-eval" { } ''
    check_value() {
      name=$1
      actual=$2
      expected=$3

      if [ "$actual" != "$expected" ]; then
        echo "$name mismatch." >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
      fi
    }

    if [ "${
      lib.boolToString (minimalService.environment ? HINDSIGHT_API_TENANT_EXTENSION)
    }" = true ]; then
      echo "minimal service must not set HINDSIGHT_API_TENANT_EXTENSION." >&2
      exit 1
    fi

    if [ "${
      lib.boolToString (configuredService.environment ? HINDSIGHT_API_DATABASE_URL)
    }" = true ]; then
      echo "configured service must load HINDSIGHT_API_DATABASE_URL from systemd credentials, not systemd environment." >&2
      exit 1
    fi

    if [ "${
      lib.boolToString (databaseUrlFileService.environment ? HINDSIGHT_API_DATABASE_URL)
    }" = true ]; then
      echo "databaseUrlFile service must not expose HINDSIGHT_API_DATABASE_URL in systemd environment." >&2
      exit 1
    fi

    if [ "${lib.boolToString minimalConfig.config.services.postgresql.enable}" != false ]; then
      echo "minimal service must not provision services.postgresql." >&2
      exit 1
    fi

    if [ "${lib.boolToString (builtins.hasAttr "hindsight-vector-init" minimalConfig.config.systemd.services)}" != false ]; then
      echo "minimal service must not define hindsight-vector-init.service." >&2
      exit 1
    fi

    check_value minimalEnvironmentFile ${lib.escapeShellArg (toString minimalEnvironmentFile)} ""
    check_value minimalLoadCredential ${lib.escapeShellArg (toString minimalService.serviceConfig.LoadCredential)} ${lib.escapeShellArg (toString expectedMinimalLoadCredential)}
    check_value minimalDatabaseUrl ${lib.escapeShellArg minimalService.environment.HINDSIGHT_API_DATABASE_URL} ${lib.escapeShellArg expectedLocalDatabaseUrl}
    check_value configuredEnvironmentFile ${lib.escapeShellArg (toString configuredEnvironmentFile)} ""
    check_value configuredLoadCredential ${lib.escapeShellArg (toString configuredService.serviceConfig.LoadCredential)} ${lib.escapeShellArg (toString expectedConfiguredLoadCredential)}
    check_value configuredPostgresqlServiceEnable ${lib.escapeShellArg (lib.boolToString configuredPostgresql.enable)} false
    check_value host ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_HOST} 127.0.0.1
    check_value port ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_PORT} 8890
    check_value logLevel ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_LOG_LEVEL} debug
    check_value databaseUrlFileEnvironmentFile ${lib.escapeShellArg (toString databaseUrlFileEnvironmentFile)} ""
    check_value databaseUrlFileLoadCredential ${lib.escapeShellArg (toString databaseUrlFileService.serviceConfig.LoadCredential)} ${lib.escapeShellArg (toString expectedDatabaseUrlFileLoadCredential)}
    if ! grep -qF '$CREDENTIALS_DIRECTORY/HINDSIGHT_API_DATABASE_URL' ${configuredService.serviceConfig.ExecStart}; then
      echo "configured service start script must load HINDSIGHT_API_DATABASE_URL from systemd credentials." >&2
      exit 1
    fi
    if ! grep -qF '$CREDENTIALS_DIRECTORY/HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY' ${configuredService.serviceConfig.ExecStart}; then
      echo "configured service start script must load HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY from systemd credentials." >&2
      exit 1
    fi
    if [ "${
      lib.boolToString (configuredService.environment ? HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY)
    }" = true ]; then
      echo "configured service must load HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY from systemd credentials, not systemd environment." >&2
      exit 1
    fi
    check_value llmProvider ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_LLM_PROVIDER} none
    check_value llmModel ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_LLM_MODEL} unused
    check_value tenantExtension ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_TENANT_EXTENSION} ${lib.escapeShellArg tenantExtension}
    check_value workerId ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_WORKER_ID} nixos-check
    check_value storeDocumentText ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_STORE_DOCUMENT_TEXT} false
    check_value embeddingsProvider ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_EMBEDDINGS_PROVIDER} openai
    check_value embeddingsModel ${lib.escapeShellArg configuredService.environment.HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL} text-embedding-3-small
    check_value home ${lib.escapeShellArg configuredService.environment.HOME} /var/lib/hindsight-check
    check_value cache ${lib.escapeShellArg configuredService.environment.XDG_CACHE_HOME} /var/cache/hindsight-check
    check_value hfHome ${lib.escapeShellArg configuredService.environment.HF_HOME} /var/cache/hindsight-check
    ${lib.optionalString (expectedTiktokenCacheDir != null)
      "check_value tiktokenCache ${lib.escapeShellArg configuredService.environment.TIKTOKEN_CACHE_DIR} ${lib.escapeShellArg (toString expectedTiktokenCacheDir)}"
    }

    touch $out
  '';

  hindsight-package-scripts = pkgs.runCommand "hindsight-package-scripts" { } ''
    for script in hindsight-api hindsight-worker hindsight-admin; do
      if [ ! -x ${pkgs.hindsight}/bin/$script ]; then
        echo "Missing executable $script in pkgs.hindsight." >&2
        exit 1
      fi
    done

    if [ -e ${pkgs.hindsight}/bin/hindsight-local-mcp ]; then
      echo "pkgs.hindsight must not ship hindsight-local-mcp; embedded pg0 is intentionally unsupported." >&2
      exit 1
    fi

    ${lib.optionalString (packageRuntimeDefaults != null) ''
      if [ "${lib.boolToString (packageRuntimeDefaults == expectedRuntimeDefaults)}" != true ]; then
        echo "pkgs.hindsight.passthru.runtimeDefaults must exactly match the slim package contract." >&2
        exit 1
      fi

      if [ "${lib.boolToString packageRuntimeDefaults.requiresDatabaseUrl}" != "${lib.boolToString expectedRuntimeDefaults.requiresDatabaseUrl}" ]; then
        echo "Unexpected pkgs.hindsight.passthru.runtimeDefaults.requiresDatabaseUrl." >&2
        exit 1
      fi

      if [ "${packageRuntimeDefaults.embeddingsProvider}" != "${expectedRuntimeDefaults.embeddingsProvider}" ]; then
        echo "Unexpected pkgs.hindsight.passthru.runtimeDefaults.embeddingsProvider." >&2
        exit 1
      fi

      if [ "${packageRuntimeDefaults.embeddingsOpenAIModel}" != "${expectedRuntimeDefaults.embeddingsOpenAIModel}" ]; then
        echo "Unexpected pkgs.hindsight.passthru.runtimeDefaults.embeddingsOpenAIModel." >&2
        exit 1
      fi

      if [ "${packageRuntimeDefaults.rerankerProvider}" != "${expectedRuntimeDefaults.rerankerProvider}" ]; then
        echo "Unexpected pkgs.hindsight.passthru.runtimeDefaults.rerankerProvider." >&2
        exit 1
      fi
    ''}

    HINDSIGHT_API_DATABASE_URL=postgresql://hindsight@127.0.0.1:5432/hindsight ${pkgs.hindsight}/bin/hindsight-api --help >/dev/null
    HINDSIGHT_API_DATABASE_URL=postgresql://hindsight@127.0.0.1:5432/hindsight ${pkgs.hindsight}/bin/hindsight-worker --help >/dev/null
    HINDSIGHT_API_DATABASE_URL=postgresql://hindsight@127.0.0.1:5432/hindsight ${pkgs.hindsight}/bin/hindsight-admin --help >/dev/null

    touch $out
  '';

  hindsight-nixos-smoke = pkgs.testers.runNixOSTest {
    name = "hindsight-nixos-smoke";

    nodes.machine =
      { config, ... }:
      {
        imports = [ hindsightModule ];

        virtualisation = {
          cores = 2;
          memorySize = 3072;
        };

        services.hindsight = {
          enable = true;
          package = pkgs.hindsight;
          databaseUrl = expectedLocalDatabaseUrl;
          logLevel = "debug";
          llmProvider = "none";
          llmModel = "unused";
          embeddingsProvider = "openai";
          embeddingsOpenAIApiKeyFile = pkgs.writeText "hindsight-test-openai-embeddings-api-key" "test-openai-key\n";
          tenantApiKeyFile = pkgs.writeText "hindsight-test-tenant-api-key" "hindsight-test-api-key\n";
          tenantExtension = tenantExtension;
          environment = {
            HINDSIGHT_API_MODEL_INIT_TIMEOUT = 5;
            HINDSIGHT_API_ENABLE_DRY_RUN_EXTRACT = false;
            HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL = "text-embedding-3-small";
            HINDSIGHT_API_RERANKER_PROVIDER = "rrf";
          };
        };
        services.postgresql = {
          enable = true;
          enableTCPIP = true;
          authentication = lib.mkBefore ''
            host hindsight hindsight 127.0.0.1/32 trust
          '';
          extensions = postgresqlPackages: [
            postgresqlPackages.pgvector
          ];
          ensureDatabases = [ "hindsight" ];
          ensureUsers = [
            {
              name = "hindsight";
              ensureDBOwnership = true;
            }
          ];
        };

        systemd.services.hindsight-vector-init = {
          description = "Initialize Hindsight PostgreSQL vector extension";
          after = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          requires = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          before = [ "hindsight.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            User = "postgres";
            Group = "postgres";
            ExecStart = pkgs.writeShellScript "hindsight-check-vector-init" ''
              set -euo pipefail

              ${config.services.postgresql.finalPackage}/bin/psql -v ON_ERROR_STOP=1 -d hindsight <<'SQL'
              CREATE EXTENSION IF NOT EXISTS vector;
              SQL
            '';
            RemainAfterExit = true;
          };
        };

        environment.systemPackages = [
          pkgs.curl
          config.services.postgresql.finalPackage
        ];

        system.stateVersion = "25.11";
      };

    testScript = ''
      def wait_for_loopback_port(port, timeout=180):
          machine.wait_until_succeeds(f"ss -ltn | grep -F '127.0.0.1:{port}'", timeout=timeout)

      try:
          machine.wait_for_unit("postgresql.service", timeout=120)
          machine.wait_until_succeeds("systemctl show hindsight-vector-init.service -P Result | grep -Fx success", timeout=120)
          machine.wait_for_unit("hindsight.service", timeout=240)
          wait_for_loopback_port(8888, timeout=120)

          machine.succeed("sudo -u postgres psql -d hindsight -tAc \"SELECT extname FROM pg_extension WHERE extname = 'vector'\" | grep -Fx vector")
          machine.succeed("systemctl show hindsight.service -P Environment | grep -F 'TIKTOKEN_CACHE_DIR=${expectedTiktokenCacheDir}'")
          machine.succeed("systemctl show hindsight.service -P Environment | grep -F 'HINDSIGHT_API_DATABASE_URL=${expectedLocalDatabaseUrl}'")
          machine.succeed("curl --noproxy '*' -fsS --max-time 30 -H 'Authorization: Bearer hindsight-test-api-key' http://127.0.0.1:8888/health")
          machine.succeed("test \"$(curl --noproxy '*' -sS -o /tmp/hindsight-unauth-banks.json -w '%{http_code}' --max-time 30 http://127.0.0.1:8888/v1/default/banks)\" = 401")
      except Exception:
          print(machine.succeed("systemctl --no-pager --full status postgresql.service hindsight-vector-init.service hindsight.service || true"))
          print(machine.succeed("journalctl --no-pager -u postgresql.service -u hindsight-vector-init.service -u hindsight.service -n 300 || true"))
          print(machine.succeed("systemctl show hindsight.service -P Environment || true"))
          print(machine.succeed("ss -ltnp || true"))
          raise
    '';
  };
}
