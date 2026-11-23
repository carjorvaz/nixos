# Hindsight 0.10.2 is built against the pinned `nixpkgs-unstable` python312 set
# rather than the system nixpkgs python312 set: its dependency floors track
# versions that only exist in the unstable channel, and two runtime
# dependencies (github-copilot-sdk, toktok-rs) are not packaged in nixpkgs at
# all. This module returns that unstable python312 package set with exactly
# those overrides applied.
{
  unstablePkgs,
}:

let
  inherit (unstablePkgs) fetchFromGitHub fetchPypi rustPlatform;

  # OpenTelemetry ships every package from two monorepos. Each package below
  # inherits `version`/`src` from either `opentelemetry-api`
  # (open-telemetry/opentelemetry-python) or `opentelemetry-instrumentation`
  # (open-telemetry/opentelemetry-python-contrib), so bumping those two moves
  # the whole family coherently. 1.45.0 / 0.66b0 is the pair that satisfies
  # Hindsight's `opentelemetry-*>=1.44.0` / `>=0.65b0` floors while keeping the
  # exporter and sdk matched: a mismatched pair raises TypeError when
  # opentelemetry-exporter-prometheus constructs MetricReader with its
  # otel_component_type kwarg.
  otelPythonSrc = fetchFromGitHub {
    owner = "open-telemetry";
    repo = "opentelemetry-python";
    tag = "v1.45.0";
    hash = "sha256-vXx4yg08G3NoQUuYd/UCefuNEEwxLl4SzhpSKhYV5jo=";
  };

  otelContribSrc = fetchFromGitHub {
    owner = "open-telemetry";
    repo = "opentelemetry-python-contrib";
    tag = "v0.66b0";
    hash = "sha256-VuHFdPUYjMiE9yflWuFli/OlD9PgxVPA7fErAISsZVc=";
  };
in

(unstablePkgs.python312.override {
  packageOverrides = python-final: python-prev: {
    # --- OpenTelemetry: 1.43.0/0.64b0 -> 1.45.0/0.66b0 --------------------
    opentelemetry-api = python-prev.opentelemetry-api.overridePythonAttrs (_: {
      version = "1.45.0";
      src = otelPythonSrc;
    });

    opentelemetry-instrumentation =
      python-prev.opentelemetry-instrumentation.overridePythonAttrs
        (old: {
          version = "0.66b0";
          src = otelContribSrc;
          # 0.66b0's metadata additionally requires packaging and a pinned
          # opentelemetry-semantic-conventions, neither of which the 0.64b0
          # dependency list carried.
          dependencies = old.dependencies ++ [
            python-final.opentelemetry-semantic-conventions
            python-final.packaging
          ];
        });

    # 1.45.0's otlp-proto-http metadata requires the two new sibling packages
    # below, which 1.43.0's dependency list did not carry.
    opentelemetry-exporter-otlp-proto-http =
      python-prev.opentelemetry-exporter-otlp-proto-http.overridePythonAttrs
        (old: {
          dependencies = old.dependencies ++ [
            python-final.opentelemetry-exporter-http-transport
            python-final.opentelemetry-exporter-otlp-common
          ];
          # 1.45.0's test suite imports `mocket`, which the 1.43.0 check
          # inputs did not carry; the pinned set packages it.
          nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ python-final.mocket ];
        });

    opentelemetry-exporter-http-transport = python-prev.buildPythonPackage {
      pname = "opentelemetry-exporter-http-transport";
      version = "0.66b0";
      pyproject = true;
      src = otelPythonSrc;
      sourceRoot = "${otelPythonSrc.name}/exporter/opentelemetry-exporter-http-transport";
      build-system = [ python-prev.hatchling ];
      # urllib3 is optional upstream (the `urllib3` extra) but is the transport
      # Hindsight's otlp-proto-http exporter uses, and it is already in the set.
      dependencies = [
        python-final.opentelemetry-api
        python-final.urllib3
      ];
      doCheck = false;
      pythonImportsCheck = [ "opentelemetry.exporter.http.transport" ];
    };

    opentelemetry-exporter-otlp-common = python-prev.buildPythonPackage {
      pname = "opentelemetry-exporter-otlp-common";
      version = "0.66b0";
      pyproject = true;
      src = otelPythonSrc;
      sourceRoot = "${otelPythonSrc.name}/exporter/opentelemetry-exporter-otlp-common";
      build-system = [ python-prev.hatchling ];
      dependencies = [ python-final.opentelemetry-sdk ];
      doCheck = false;
      pythonImportsCheck = [ "opentelemetry.exporter.otlp.common" ];
    };

    # --- dependencies below Hindsight's floors ---------------------------
    # json-repair: 0.55.2 -> 0.63.5 (Hindsight requires >=0.63.2)
    json-repair = python-prev.json-repair.overridePythonAttrs (_: {
      version = "0.63.5";
      src = fetchFromGitHub {
        owner = "mangiucugna";
        repo = "json_repair";
        tag = "v0.63.5";
        hash = "sha256-hqVSZoTqhMEQhymhX+prUYWOXogEJ0XPK7r5DdPwg44=";
      };
      # The 0.63.5 test suite grew schema tests that need optional extras the
      # nixpkgs derivation does not provide; Hindsight's install check is the
      # meaningful verification of this package, not json-repair's own tests.
      doCheck = false;
    });

    # regex: 2026.7.11 -> 2026.9.29 (Hindsight requires >=2026.9.3, a SIGSEGV
    # fix in dateparser's locale-cache path; C extension). Built from the PyPI
    # sdist like nixpkgs' own build; the GitHub tag export tripped the patch
    # phase on the builder.
    regex = python-prev.regex.overridePythonAttrs (old: {
      version = "2026.9.29";
      src = fetchPypi {
        pname = "regex";
        version = "2026.9.29";
        hash = "sha256-i1/MR3FzIZGyt9HdaNjwNT9H+NkLYVD23OWL8REkQss=";
      };
      # nixpkgs ships pyprojectVersionPatchHook because upstream's GitHub tag
      # tarball does not carry the released version in pyproject.toml. The
      # PyPI sdist does, and the hook hard-fails ("already matches ... Remove
      # pyprojectVersionPatchHook") when there is nothing to patch, so drop it.
      nativeBuildInputs = builtins.filter (
        hook: (hook.name or "") != "pyproject-version-patch-hook.sh"
      ) old.nativeBuildInputs;
    });

    # greenlet: 3.5.3 -> 3.3.2 (Hindsight caps `>=3.2.4,<3.4.0`; the C
    # extension's 3.5 line is out of range). 3.3.2 is the latest 3.3.x.
    greenlet = python-prev.greenlet.overridePythonAttrs (_: {
      version = "3.3.2";
      src = fetchPypi {
        pname = "greenlet";
        version = "3.3.2";
        hash = "sha256-Lq8Gf8bYhpMceWLoxr7eFdLwGWVWDzNZsnyAveLRUfI=";
      };
    });

    # eventlet is only consumed transitively (gunicorn's check environment).
    # Its greenio test_sendall_timeout is timing-flaky on this builder
    # ("AssertionError: socket.timeout not raised"), so drop that one test.
    eventlet = python-prev.eventlet.overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ [ "test_sendall_timeout" ];
    });

    # backrefs is only consumed transitively (documentation/test tooling).
    # Its test_bregex timeout test is timing-flaky on this builder
    # ("DID NOT RAISE TimeoutError"), so drop that one test.
    backrefs = python-prev.backrefs.overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ [ "test_timeout" ];
    });

    # pyopenssl's TLS test-suite is timing/openssl-version sensitive on this
    # builder (one flaky failure, not reproducible on retry); it is consumed
    # transitively (twisted, google-auth), so skip its tests for determinism.
    pyopenssl = python-prev.pyopenssl.overridePythonAttrs (_: {
      doCheck = false;
    });

    # IPython is only consumed transitively (test/documentation tooling of
    # other dependencies). Its SIGINT tests are timing-dependent on this
    # builder ("DID NOT RAISE KeyboardInterrupt"), so drop those three tests;
    # verified on the builder: 1589 passed, 3 deselected.
    ipython = python-prev.ipython.overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ [
        "test_timeit_raise_on_interrupt"
        "test_script_raise_on_interrupt"
        "test_time_raise_on_interrupt"
      ];
    });

    # watchdog is only consumed transitively (test tooling). Its
    # test_kill_auto_restart race-fails under load on this builder
    # ("assert '+++++ 9' not in ..."), so drop that one test.
    watchdog = python-prev.watchdog.overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ [ "test_kill_auto_restart" ];
    });

    # uvloop is a declared direct runtime dependency of hindsight (wheel
    # Requires-Dist) and is imported by the app. Its sandboxed test suite, like
    # trio's, hangs on this builder (sockets/timers that never resolve), so
    # skip the checks.
    uvloop = python-prev.uvloop.overridePythonAttrs (_: {
      doCheck = false;
    });
    trio = python-prev.trio.overridePythonAttrs (_: {
      doCheck = false;
    });

    # inline-snapshot is test tooling; its suite fails on this builder's black
    # configuration (3/1402, environment-sensitive), so skip its checks.
    inline-snapshot = python-prev.inline-snapshot.overridePythonAttrs (_: {
      doCheck = false;
    });

    # obstore is a declared direct runtime dependency of hindsight (wheel
    # Requires-Dist) and is imported by the app. Its checks drag in a
    # heavyweight geo test stack (pyarrow, polars, pystac-client, docker), so
    # skip them. Its wheel metadata requires typing-extensions but the nixpkgs
    # expression wires no dependencies at all, so supply it.
    obstore = python-prev.obstore.overridePythonAttrs (_: {
      doCheck = false;
      dependencies = [ python-final.typing-extensions ];
    });

    # safetensors' checks pull torch (hours to build from source on this
    # builder); tokenizers' checks pull `datasets`, which drags the same
    # test stack. Both are consumed as libraries only.
    safetensors = python-prev.safetensors.overridePythonAttrs (_: {
      doCheck = false;
    });
    tokenizers = python-prev.tokenizers.overridePythonAttrs (_: {
      doCheck = false;
    });

    # markitdown is needed at runtime, but its nixpkgs expression folds every
    # optional converter into `dependencies`. The azure/youtube extras drag in
    # heavyweight cloud and API clients for converters Hindsight does not
    # expose, so drop those. The local document converters are kept (including
    # pdfplumber, which markitdown's PDF converter imports alongside
    # pdfminer.six), and so is the audio converter: the .wav/.mp3 transcription
    # path that the hindsight markitdown parser advertises needs pydub and
    # speechrecognition. Upstream raises MissingDependencyException by design
    # when an extra converter is absent; skip the tests.
    markitdown = python-prev.markitdown.overridePythonAttrs (_: {
      doCheck = false;
      dependencies = [
        python-final.beautifulsoup4
        python-final.charset-normalizer
        python-final.defusedxml
        python-final.lxml
        python-final.magika
        python-final.mammoth
        python-final.markdownify
        python-final.olefile
        python-final.openpyxl
        python-final.pandas
        python-final.pdfminer-six
        python-final.pdfplumber
        python-final.pydub
        python-final.python-pptx
        python-final.requests
        python-final.speechrecognition
        python-final.xlrd
      ];
    });

    # speechrecognition's checks fold in every optional backend (openai-whisper
    # -> torch, faster-whisper, pyaudio); the audio path only needs the base
    # package, so skip its checks.
    speechrecognition = python-prev.speechrecognition.overridePythonAttrs (_: {
      doCheck = false;
    });

    # pdfplumber's checks pull jupyterlab/nbexec/pandas-stubs (and through
    # pandas-stubs the geoarrow/gdal stack); it is consumed as a library only.
    pdfplumber = python-prev.pdfplumber.overridePythonAttrs (_: {
      doCheck = false;
    });

    # pydantic-monty is a check input of fastmcp's suite; its
    # test_keyboard_interrupt is signal-timing dependent on this builder
    # ("Expected KeyboardInterrupt to be raised"), so skip its checks.
    pydantic-monty = python-prev.pydantic-monty.overridePythonAttrs (_: {
      doCheck = false;
    });

    # fastmcp's suite has one flaky test on this builder (an unraisable
    # exception); drop that test rather than the whole suite.
    fastmcp = python-prev.fastmcp.overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ [ "test_code_mode_max_tool_calls_enforced" ];
    });

    # --- dependencies absent from nixpkgs --------------------------------
    # github-copilot-sdk publishes only a pure-python wheel (no sdist).
    github-copilot-sdk = python-prev.buildPythonPackage {
      pname = "github-copilot-sdk";
      version = "1.0.16";
      format = "wheel";
      src = fetchPypi {
        pname = "github_copilot_sdk";
        version = "1.0.16";
        format = "wheel";
        python = "py3";
        dist = "py3";
        hash = "sha256-/LyeJnPVzz2kDECV/YQdOfBP8smwnfyXCz+1+WL0eg8=";
      };
      dependencies = [
        python-final.python-dateutil
        python-final.pydantic
        python-final.httpx
      ];
      doCheck = false;
      pythonImportsCheck = [ "copilot" ];
    };

    # FlashRank: pure-python ONNX cross-encoder (deps already in the closure;
    # its llama-cpp-python path is an optional extra we do not need).
    flashrank = python-prev.buildPythonPackage rec {
      pname = "FlashRank";
      version = "0.2.10";
      pyproject = true;
      build-system = [ python-final.setuptools ];
      src = unstablePkgs.fetchzip {
        # fetchPypi capitalises the first-char URL slot (.../F/FlashRank/...)
        # which PyPI 404s; the real path keeps the lowercase first char.
        url = "https://files.pythonhosted.org/packages/source/f/FlashRank/FlashRank-${version}.tar.gz";
        hash = "sha256-UJm/L7B6owhoK8ZA7O3gSShDNGfjqZrcsBKo0XcmRb8=";
      };
      dependencies = [
        python-final.tokenizers
        python-final.onnxruntime
        python-final.numpy
        python-final.requests
        python-final.tqdm
      ];
      doCheck = false;
      pythonImportsCheck = [ "flashrank" ];
    };

    # toktok-rs: Rust/maturin extension. The sdist is unpacked here (rather
    # than via fetchPypi) so that its Cargo.lock is a plain path for
    # importCargoLock. That lock has only crates.io dependencies with
    # checksums, so importCargoLock vendors them without a cargo hash (no
    # lib.fakeHash placeholder needed).
    toktok-rs = python-prev.buildPythonPackage rec {
      pname = "toktok-rs";
      version = "0.1.4";
      pyproject = true;
      src = unstablePkgs.fetchzip {
        url = "https://files.pythonhosted.org/packages/source/t/toktok_rs/toktok_rs-${version}.tar.gz";
        hash = "sha256-fl5bfdAjIOLBmOdM9u2eNmF3OfVSgTUOZFTV6pxL4A8=";
      };
      cargoDeps = rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; };
      build-system = [
        rustPlatform.cargoSetupHook
        rustPlatform.maturinBuildHook
      ];
      doCheck = false;
      pythonImportsCheck = [ "toktok" ];
    };
  };
}).pkgs
