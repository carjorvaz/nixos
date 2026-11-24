{
  lib,
  pkgs,
  inputs,
  fetchPypi,
  fetchurl,
  nix-update-script,
  runCommand,
  withLocalOnnx ? false,
}:

let
  # mkLocalPackages hands every local package that declares `inputs` the
  # flake's input set. hindsight 0.10.2's dependency floors need the pinned
  # nixpkgs-unstable python312 packages instead of the system (nixos-26.05)
  # ones; the local overrides live in python-env.nix.
  unstablePkgs = import inputs.nixpkgs-unstable.outPath {
    system = pkgs.stdenv.hostPlatform.system;
  };

  ps = import ./python-env.nix { inherit unstablePkgs; };

  markitdownDocumentDeps = with ps; [
    lxml
    mammoth
    openpyxl
    pandas
    pdfminer-six
    python-pptx
    xlrd
  ];

  # The withLocalOnnx variant is what the pius deploy runs; assert that its
  # local embeddings stack actually imports, not merely that the attribute
  # exists. HOME is pointed at the build's scratch space because importing
  # huggingface_hub/transformers touches the home cache directory.
  localOnnxInstallCheck = lib.optionalString withLocalOnnx ''
    export HOME=$TMPDIR
    ${ps.python.interpreter} - <<'ONNXPY'
    import onnxruntime
    import tokenizers
    import transformers
    import huggingface_hub
    import flashrank
    import hindsight_api.engine.embeddings

    print("hindsight installCheck: ONNX embeddings stack imported")
    ONNXPY
  '';

  # The complete 0.10.2 core `Requires-Dist` set, resolved from the private
  # python312 set above. Compared to 0.8.6 upstream dropped langchain-core,
  # langchain-text-splitters, langsmith and (in favour of toktok) tiktoken,
  # and added github-copilot-sdk, regex and toktok-rs. psycopg2-binary is
  # removed below; pg0-embedded is only an `embedded-db` extra, not core.
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
      github-copilot-sdk
      google-auth
      google-genai
      greenlet
      httpx
      json-repair
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
      regex
      rich
      sqlalchemy
      # Not a 0.10.2 core dependency (toktok replaced it for Hindsight's own
      # token counting), but litellm still uses it for token/cost accounting,
      # and the seeded offline cache wrapped in via TIKTOKEN_CACHE_DIR below is
      # what lets that path run without network I/O.
      tiktoken
      toktok-rs
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
    flashrank
  ];

  cl100kBaseTiktoken = fetchurl {
    url = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken";
    hash = "sha256-Ijkht27pm96ZW3/3OFE+7xAPtR0YyTWXoRO8/+hlsqc=";
  };

  # tiktoken caches encoding downloads by SHA-1 of the source URL. Seed the
  # cache with cl100k_base so litellm's token/cost accounting can run without
  # network I/O. (Hindsight's own tokenizer is toktok, whose vocabularies are
  # compiled into its extension module and need no cache.)
  tiktokenCacheDir = runCommand "hindsight-tiktoken-cache" { } ''
    install -Dm444 ${cl100kBaseTiktoken} \
      "$out/9b5ad71b2ce5302211f9c61530b329a4922fc6a4"
  '';
in

ps.buildPythonApplication rec {
  pname = "hindsight-api-slim";
  version = "0.10.2";
  pyproject = true;

  disabled = ps.pythonOlder "3.11";

  src = fetchPypi {
    pname = "hindsight_api_slim";
    inherit version;
    hash = "sha256-9mYWfxyDFEoSngZDH0a4buJ8jgKMm4Lq3Jhgp6a0N9Q=";
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

    # The strata lease front-end (pkgs/strata-lease-proxy.py) answers 503 +
    # Retry-After while an interactive conversation holds the single-slot
    # engine, and 502 + Retry-After when the engine is not listening at all.
    # Upstream's durable-defer classifier is 429-only, so lease backpressure
    # burns the in-call retry loop and eventually fails the operation
    # outright. Extending the accepted statuses converts those responses into
    # ProviderRateLimitResetError, which memory_engine turns into
    # DeferOperation and poller._defer_operation resets to pending at
    # next_retry_at without bumping retry_count; the wall-clock ceiling is
    # per claimed execution, so a deferred retain is durable until the lane
    # frees. The Retry-After parsing and the defer plumbing already exist in
    # 0.10.2; this only widens the gate. Asserted in installCheck below.
    provider = Path("hindsight_api/engine/providers/openai_compatible_llm.py")
    text = provider.read_text()
    provider_replacements = {
        '    if e.status_code != 429:\n        return\n    retry_at = _rate_limit_retry_at(e)\n':
            '    if e.status_code not in (429, 502, 503, 504):\n'
            '        return\n    retry_at = _rate_limit_retry_at(e)\n',
        'f"Provider quota exhausted ({provider}/{model}, scope={scope}); retry at {retry_at.isoformat()}: {summary}"':
            'f"Provider backpressure (HTTP {e.status_code}; {provider}/{model}, scope={scope}); retry at {retry_at.isoformat()}: {summary}"',
    }
    for old, new in provider_replacements.items():
        if old not in text:
            raise RuntimeError(f"missing expected source text: {old!r}")
        text = text.replace(old, new, 1)
    provider.write_text(text)
    entrypoints = {
        Path("hindsight_api/main.py"): (
            '    DEFAULT_ACCESS_LOG,\n'
            '    DEFAULT_HOST,\n'
            '    DEFAULT_WORKERS,\n'
            '    ENV_ACCESS_LOG,\n'
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
            '            workers=int(os.getenv(ENV_WORKERS, DEFAULT_WORKERS)),\n'
            '            access_log=DEFAULT_ACCESS_LOG,\n'
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

  build-system = [ ps.hatchling ];

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
    # pinned nixpkgs-unstable python312 set. Hindsight does not exercise the
    # version-specific APIs the floors were raised for, so the set's versions
    # are accepted:
    #
    # boto3: >=1.42.74 -> 1.42.31 (optional AWS/S3 paths only)
    "boto3"
  ];

  # Upstream declares psycopg2-binary, but nixpkgs correctly provides psycopg2
  # linked against the system libpq instead of vendoring binary wheels.
  pythonRemoveDeps = [ "psycopg2-binary" ];

  # The sdist does not ship an isolated test suite suitable for nix builds.
  # doCheck must stay true because mk-python-derivation derives
  # doInstallCheck from it (doInstallCheck = attrs.doCheck or true), and the
  # install check below is this package's smoke: imports, entrypoints and the
  # packaged Alembic assets, without requiring a running PostgreSQL/LLM
  # service. No checkPhase is defined on purpose: mk-python-derivation sets
  # installCheckPhase from attrs.checkPhase, so declaring one would replace
  # the smoke instead of adding a phase.
  doCheck = true;

  strictDeps = true;

  # `hindsight_api.main` loads the config at import time, and the config
  # requires an external database URL; the import check below imports main and
  # worker.main, so give it a placeholder. The installCheck smoke clears all
  # HINDSIGHT_API_* variables first, so it is unaffected, and the NixOS module
  # sets the real value at run time.
  HINDSIGHT_API_DATABASE_URL = "postgresql://hindsight@127.0.0.1:5432/hindsight";

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

    # Upstream 0.10.2 escapes '%' before handing the URL to Alembic's
    # ConfigParser; exercise the shipped helper to guard against regression.
    alembic_config = Config()
    _set_alembic_main_option(alembic_config, "sqlalchemy.url", encoded_socket_url)
    assert alembic_config.get_main_option("sqlalchemy.url") == encoded_socket_url

    # opentelemetry-exporter-prometheus is overridden to 0.66b0 alongside the
    # matching 1.45.0 sdk (see python-env.nix); constructing the reader with
    # the exporter/sdk pair skewed would raise TypeError on the
    # otel_component_type kwarg.
    from opentelemetry.exporter.prometheus import PrometheusMetricReader

    PrometheusMetricReader()

    # tiktoken must still resolve cl100k_base from the seeded offline cache;
    # litellm uses tiktoken for token/cost accounting even though Hindsight's
    # own token counting moved to toktok.
    import tiktoken

    assert tiktoken.get_encoding("cl100k_base").encode("hindsight offline tokenizer check")

    # Hindsight 0.10.2 counts tokens with toktok, whose vocabularies are
    # compiled into the extension module (no cache or network at runtime).
    from hindsight_api.engine.token_encoding import count_tokens

    assert count_tokens("hindsight offline tokenizer check") > 0

    scripts = {
        "hindsight-api": "hindsight_api.main",
        "hindsight-worker": "hindsight_api.worker.main",
        "hindsight-admin": "hindsight_api.admin.cli",
    }
    for module in scripts.values():
        __import__(module)

    # Lease-backpressure postPatch (see above): a 503 + Retry-After from the
    # strata lease front-end must convert into the durable defer path —
    # ProviderRateLimitResetError, which memory_engine turns into a
    # DeferOperation that does not consume retry_count — while a 5xx without
    # Retry-After keeps upstream's in-call retry semantics.
    import httpx
    from datetime import UTC, datetime, timedelta

    from openai._exceptions import InternalServerError

    from hindsight_api.engine.llm_interface import ProviderRateLimitResetError
    from hindsight_api.engine.providers.openai_compatible_llm import (
        _raise_provider_quota_defer,
    )

    request = httpx.Request("POST", "http://tiberius.invalid/v1/chat/completions")
    err503 = InternalServerError(
        "lease held",
        response=httpx.Response(503, headers={"Retry-After": "120"}, request=request),
        body=None,
    )
    try:
        _raise_provider_quota_defer(
            err503, provider="openai", model="m", scope="s", max_backoff=60.0
        )
    except ProviderRateLimitResetError as e:
        now = datetime.now(UTC)
        assert now + timedelta(seconds=110) < e.retry_at < now + timedelta(seconds=135), e.retry_at
    else:
        raise AssertionError("503 + Retry-After did not raise ProviderRateLimitResetError")

    err500 = InternalServerError("boom", response=httpx.Response(500, request=request), body=None)
    assert _raise_provider_quota_defer(
        err500, provider="openai", model="m", scope="s", max_backoff=60.0
    ) is None

    alembic = resources.files("hindsight_api") / "alembic"
    versions = alembic / "versions"
    assert alembic.is_dir(), "missing alembic directory"
    assert (alembic / "env.py").is_file(), "missing alembic env.py"
    assert versions.is_dir(), "missing alembic versions directory"
    assert any(version.name.endswith(".py") and version.is_file() for version in versions.iterdir()), "missing alembic version files"
    print("hindsight installCheck: python assertions passed")
    PY

    ${localOnnxInstallCheck}
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
    # Restricted to x86_64-linux, the deployment target. Upstream 0.10.2's
    # `cryptography>=50.0.0` floor is satisfied by the pinned nixpkgs-unstable
    # set (50.0.0); the other platforms are untested here.
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
  };
}
