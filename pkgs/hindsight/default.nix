{
  lib,
  fetchPypi,
  fetchurl,
  nix-update-script,
  runCommand,
  python3Packages,
  withLocalOnnx ? false,
}:

let
  ps = python3Packages;

  markitdownDocumentDeps = with ps; [
    lxml
    mammoth
    openpyxl
    pandas
    pdfminer-six
    python-pptx
    xlrd
  ];

  runtimeDeps =
    with ps;
    [
      aiohttp
      alembic
      anthropic
      asyncpg
      authlib
      boto3
      claude-agent-sdk
      cohere
      croniter
      cryptography
      dateparser
      fastapi
      fastmcp
      filelock
      google-auth
      google-genai
      greenlet
      httpx
      json-repair
      langchain-core
      langchain-text-splitters
      langsmith
      litellm
      markitdown
      numpy
      obstore
      openai
      opentelemetry-api
      opentelemetry-exporter-otlp-proto-http
      opentelemetry-exporter-prometheus
      opentelemetry-instrumentation-fastapi
      opentelemetry-sdk
      opentelemetry-semantic-conventions
      orjson
      pgvector
      pillow
      protobuf
      psycopg2
      pyasn1
      pydantic
      pygments
      pyjwt
      python-dateutil
      python-dotenv
      python-multipart
      rich
      sqlalchemy
      tiktoken
      tornado
      typer
      urllib3
      uvicorn
      uvloop
      wsproto
    ]
    ++ markitdownDocumentDeps;

  localOnnxDeps = with ps; [
    huggingface-hub
    onnxruntime
    tokenizers
    transformers
  ];

  cl100kBaseTiktoken = fetchurl {
    url = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken";
    hash = "sha256-Ijkht27pm96ZW3/3OFE+7xAPtR0YyTWXoRO8/+hlsqc=";
  };

  # tiktoken caches encoding downloads by SHA-1 of the source URL. Seed the
  # cache with cl100k_base so Hindsight can start without runtime network I/O.
  tiktokenCacheDir = runCommand "hindsight-tiktoken-cache" { } ''
    install -Dm444 ${cl100kBaseTiktoken} \
      "$out/9b5ad71b2ce5302211f9c61530b329a4922fc6a4"
  '';
in

ps.buildPythonApplication rec {
  pname = "hindsight-api-slim";
  version = "0.8.6";
  pyproject = true;

  disabled = ps.pythonOlder "3.11";

  src = fetchPypi {
    pname = "hindsight_api_slim";
    inherit version;
    hash = "sha256-zxlACmLMCBnChbQRs83QBgJDAwt0WBt/PHuZeKx5G4s=";
  };

  postPatch = ''
    ${ps.python.interpreter} - <<'PY'
    from pathlib import Path

    config = Path("hindsight_api/config.py")
    text = config.read_text()
    replacements = {
        'DEFAULT_DATABASE_URL = "pg0"': 'DEFAULT_DATABASE_URL = None',
        'DEFAULT_EMBEDDINGS_PROVIDER = "local"': 'DEFAULT_EMBEDDINGS_PROVIDER = "openai"',
        'DEFAULT_RERANKER_PROVIDER = "local"': 'DEFAULT_RERANKER_PROVIDER = "rrf"',
        '        # Validate vector_extension\n        validate_extension(self.vector_extension)':
            '        if not self.database_url:\n'
            '            raise ValueError("HINDSIGHT_API_DATABASE_URL must be set to an external PostgreSQL database URL")\n'
            '\n'
            '        # Validate vector_extension\n'
            '        validate_extension(self.vector_extension)',
    }
    for old, new in replacements.items():
        if old not in text:
            raise RuntimeError(f"missing expected source text: {old!r}")
        text = text.replace(old, new, 1)
    config.write_text(text)
    entrypoints = {
        Path("hindsight_api/main.py"): (
            '    DEFAULT_ACCESS_LOG,\n'
            '    DEFAULT_WORKERS,\n'
            '    ENV_ACCESS_LOG,\n'
            '    ENV_HOST,\n'
            '    ENV_WORKERS,\n'
            '    HindsightConfig,\n'
            '    _get_raw_config,\n',
            '    DEFAULT_ACCESS_LOG,\n'
            '    DEFAULT_HOST,\n'
            '    DEFAULT_LOG_LEVEL,\n'
            '    DEFAULT_PORT,\n'
            '    DEFAULT_WORKERS,\n'
            '    ENV_ACCESS_LOG,\n'
            '    ENV_HOST,\n'
            '    ENV_LOG_LEVEL,\n'
            '    ENV_PORT,\n'
            '    ENV_WORKERS,\n'
            '    HindsightConfig,\n'
            '    _get_raw_config,\n',
            '    # Load configuration from environment (for CLI args defaults)\n'
            '    config = _get_raw_config()\n',
            '    # --help must not require service-only configuration such as the database URL.\n'
            '    if any(arg in ("-h", "--help") for arg in sys.argv[1:]):\n'
            '        config = argparse.Namespace(\n'
            '            host=os.getenv(ENV_HOST, DEFAULT_HOST),\n'
            '            port=int(os.getenv(ENV_PORT, DEFAULT_PORT)),\n'
            '            log_level=os.getenv(ENV_LOG_LEVEL, DEFAULT_LOG_LEVEL),\n'
            '        )\n'
            '    else:\n'
            '        # Load configuration from environment (for CLI args defaults)\n'
            '        config = _get_raw_config()\n',
        ),
        Path("hindsight_api/worker/main.py"): (
            'from ..config import get_config, load_dotenv_for_entrypoint\n',
            'from ..config import (\n'
            '    DEFAULT_LOG_LEVEL,\n'
            '    DEFAULT_WORKER_HTTP_PORT,\n'
            '    DEFAULT_WORKER_ID,\n'
            '    DEFAULT_WORKER_MAX_RETRIES,\n'
            '    DEFAULT_WORKER_POLL_INTERVAL_MS,\n'
            '    ENV_LOG_LEVEL,\n'
            '    ENV_WORKER_HTTP_PORT,\n'
            '    ENV_WORKER_ID,\n'
            '    ENV_WORKER_MAX_RETRIES,\n'
            '    ENV_WORKER_POLL_INTERVAL_MS,\n'
            '    get_config,\n'
            '    load_dotenv_for_entrypoint,\n'
            ')\n',
            '    # Load configuration from environment\n'
            '    config = get_config()\n',
            '    # --help must not require service-only configuration such as the database URL.\n'
            '    if any(arg in ("-h", "--help") for arg in sys.argv[1:]):\n'
            '        config = argparse.Namespace(\n'
            '            worker_id=os.getenv(ENV_WORKER_ID) or DEFAULT_WORKER_ID,\n'
            '            worker_poll_interval_ms=int(os.getenv(ENV_WORKER_POLL_INTERVAL_MS, str(DEFAULT_WORKER_POLL_INTERVAL_MS))),\n'
            '            worker_max_retries=int(os.getenv(ENV_WORKER_MAX_RETRIES, str(DEFAULT_WORKER_MAX_RETRIES))),\n'
            '            worker_http_port=int(os.getenv(ENV_WORKER_HTTP_PORT, str(DEFAULT_WORKER_HTTP_PORT))),\n'
            '            log_level=os.getenv(ENV_LOG_LEVEL, DEFAULT_LOG_LEVEL),\n'
            '        )\n'
            '    else:\n'
            '        # Load configuration from environment\n'
            '        config = get_config()\n',
        ),
    }
    for path, replacements_for_path in entrypoints.items():
        text = path.read_text()
        for old, new in zip(replacements_for_path[0::2], replacements_for_path[1::2]):
            if old not in text:
                raise RuntimeError(f"missing expected source text in {path}: {old!r}")
            text = text.replace(old, new, 1)
        path.write_text(text)

    pyproject = Path("pyproject.toml")
    text = pyproject.read_text()
    old = 'hindsight-local-mcp = "hindsight_api.mcp_local:main"\n'
    if old not in text:
        raise RuntimeError(f"missing expected source text: {old!r}")
    text = text.replace(old, "", 1)
    pyproject.write_text(text)
    PY
  '';

  "build-system" = [ ps.hatchling ];

  nativeBuildInputs = [
    ps.pythonRelaxDepsHook
    ps.pythonCatchConflictsHook
  ];

  makeWrapperArgs = [
    "--set-default"
    "TIKTOKEN_CACHE_DIR"
    tiktokenCacheDir
  ];

  dependencies = runtimeDeps ++ lib.optionals withLocalOnnx localOnnxDeps;

  pythonRelaxDeps = [
    # The packages below carry upstream floors newer than the versions in the
    # pinned nixpkgs python312 set (rev cf5e7650, 2026-09-27). Hindsight does
    # not exercise the version-specific APIs the floors were raised for, so the
    # nixpkgs versions are accepted. Each entry lists floor -> nixpkgs:
    #
    # boto3: >=1.42.74 -> 1.42.31
    "boto3"
    # cryptography: >=48.0.1 (GHSA-537c-gmf6-5ccf) -> 48.0.0
    "cryptography"
    # langsmith: >=0.8.18 (GHSA-f4xh-w4cj-qxq8) -> 0.7.37
    "langsmith"
    # litellm: >=1.93.0 -> 1.86.0
    "litellm"
    # protobuf: >=7.35.1 -> 7.34.1
    "protobuf"
    # opentelemetry: >=1.44.0 / >=0.65b0 -> 1.34.0 / 0.55b0
    "opentelemetry-api"
    "opentelemetry-exporter-otlp-proto-http"
    "opentelemetry-exporter-prometheus"
    "opentelemetry-instrumentation-fastapi"
    "opentelemetry-sdk"
    "opentelemetry-semantic-conventions"
  ];

  # Upstream declares psycopg2-binary, but nixpkgs correctly provides psycopg2
  # linked against the system libpq instead of vendoring binary wheels.
  pythonRemoveDeps = [ "psycopg2-binary" ];

  # The sdist does not ship an isolated test suite suitable for nix builds.
  # Install checks below cover imports, entrypoints, and packaged Alembic assets
  # without requiring a running PostgreSQL/LLM service.
  doCheck = false;

  strictDeps = true;

  pythonImportsCheck = [
    "hindsight_api"
    "hindsight_api.main"
    "hindsight_api.worker.main"
  ];

  doInstallCheck = true;

  installCheckPhase = ''
    runHook preInstallCheck

    # Makes the derivation depend on the seeded tiktoken cache and lets the
    # offline tokenizer assertion below resolve cl100k_base without network.
    export TIKTOKEN_CACHE_DIR=${tiktokenCacheDir}

    for program in hindsight-api hindsight-worker hindsight-admin; do
      test -x "$out/bin/$program"
      "$out/bin/$program" --help >/dev/null
    done
    test ! -e "$out/bin/hindsight-local-mcp"

    ${ps.python.interpreter} - <<'PY'
    import importlib.resources as resources
    import os

    for key in list(os.environ):
        if key.startswith("HINDSIGHT_API_"):
            del os.environ[key]

    from hindsight_api.config import (
        DEFAULT_DATABASE_URL,
        DEFAULT_EMBEDDINGS_OPENAI_MODEL,
        DEFAULT_EMBEDDINGS_PROVIDER,
        DEFAULT_RERANKER_PROVIDER,
        HindsightConfig,
    )

    assert DEFAULT_DATABASE_URL is None
    assert DEFAULT_EMBEDDINGS_PROVIDER == "openai"
    assert DEFAULT_EMBEDDINGS_OPENAI_MODEL == "text-embedding-3-small"
    assert DEFAULT_RERANKER_PROVIDER == "rrf"

    try:
        HindsightConfig.from_env()
    except ValueError as exc:
        assert "HINDSIGHT_API_DATABASE_URL" in str(exc)
    else:
        raise AssertionError("HindsightConfig.from_env() accepted a missing database URL")

    os.environ["HINDSIGHT_API_DATABASE_URL"] = "postgresql://hindsight@127.0.0.1:5432/hindsight"
    config = HindsightConfig.from_env()
    assert config.database_url == "postgresql://hindsight@127.0.0.1:5432/hindsight"
    assert config.embeddings_provider == "openai"
    assert config.reranker_provider == "rrf"

    from alembic.config import Config
    from hindsight_api.db_url import to_libpq_url
    from hindsight_api.migrations import _set_alembic_main_option

    socket_url = "postgresql://hindsight@/hindsight?host=/run/postgresql"
    encoded_socket_url = "postgresql://hindsight@/hindsight?host=%2Frun%2Fpostgresql"
    assert to_libpq_url(socket_url) == encoded_socket_url

    # Upstream 0.8.6 escapes '%' before handing the URL to Alembic's
    # ConfigParser; exercise the shipped helper to guard against regression.
    alembic_config = Config()
    _set_alembic_main_option(alembic_config, "sqlalchemy.url", encoded_socket_url)
    assert alembic_config.get_main_option("sqlalchemy.url") == encoded_socket_url

    # opentelemetry-exporter-prometheus >=0.65b0 passes otel_component_type= to
    # MetricReader.__init__, which only opentelemetry-sdk >=1.41.0 accepts;
    # constructing the reader raises TypeError on a skewed exporter/sdk pair.
    # (0.55b0 in the pinned nixpkgs takes no such kwarg.)
    from opentelemetry.exporter.prometheus import PrometheusMetricReader

    PrometheusMetricReader()

    # tiktoken must resolve cl100k_base from the seeded offline cache.
    from hindsight_api.engine.token_encoding import get_token_encoding

    assert get_token_encoding().encode("hindsight offline tokenizer check")

    scripts = {
        "hindsight-api": "hindsight_api.main",
        "hindsight-worker": "hindsight_api.worker.main",
        "hindsight-admin": "hindsight_api.admin.cli",
    }
    for module in scripts.values():
        __import__(module)

    alembic = resources.files("hindsight_api") / "alembic"
    versions = alembic / "versions"
    assert alembic.is_dir(), "missing alembic directory"
    assert (alembic / "env.py").is_file(), "missing alembic env.py"
    assert versions.is_dir(), "missing alembic versions directory"
    assert any(version.name.endswith(".py") and version.is_file() for version in versions.iterdir()), "missing alembic version files"
    PY

    runHook postInstallCheck
  '';

  passthru = {
    inherit tiktokenCacheDir;
    supportsLocalOnnx = withLocalOnnx;
    supportsLocalMl = false;
    # Exposed for checks to validate that the packaged defaults stay in sync
    # with the postPatch modifications. Must match what postPatch writes.
    runtimeDefaults = {
      requiresDatabaseUrl = true;
      embeddingsProvider = "openai";
      embeddingsOpenAIModel = "text-embedding-3-small";
      rerankerProvider = "rrf";
    };
    updateScript = nix-update-script { };
  };

  meta = {
    description = "Native Python API service for Hindsight agent memory";
    longDescription = ''
      Hindsight is an agent memory service with temporal, semantic, and entity
      memory over PostgreSQL. This package builds the upstream hindsight-api-slim
      Python API service for deployments that provide an external PostgreSQL
      database with pgvector. Embedded pg0 PostgreSQL is not supported, and the
      hindsight-local-mcp console script is intentionally not installed.
    '';
    homepage = "https://hindsight.vectorize.io";
    changelog = "https://pypi.org/project/hindsight-api-slim/${version}/";
    license = lib.licenses.asl20;
    maintainers = [
      {
        name = "Carlos Vaz";
        email = "carlos@carjorvaz.com";
        github = "carjorvaz";
        githubId = 21079473;
      }
    ];
    mainProgram = "hindsight-api";
    # Restricted to x86_64-linux, the deployment target. Upstream 0.8.6 lifted
    # the cryptography <47 ARM64 SIGILL cap; nixpkgs ships 48.0.0, below the
    # upstream >=48.0.1 floor relaxed in pythonRelaxDeps, so the other
    # platforms are untested here.
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
  };
}
