{
  lib,
  python3Packages,
}:

python3Packages.buildPythonApplication rec {
  pname = "cloakbrowser-python";
  version = "0.4.8";
  pyproject = true;
  disabled = python3Packages.pythonOlder "3.9";

  src = python3Packages.fetchPypi {
    pname = "cloakbrowser";
    inherit version;
    hash = "sha256-WESzbpNlRsZ9BcyTB+VFY2bpYOBHPqgNVg8ZImFHs7A=";
  };

  build-system = with python3Packages; [ hatchling ];

  dependencies = with python3Packages; [
    cryptography
    httpx
    playwright
  ];

  pythonImportsCheck = [ "cloakbrowser" ];

  meta = {
    description = "Python wrapper and CLI for CloakBrowser automation";
    homepage = "https://github.com/CloakHQ/CloakBrowser";
    license = lib.licenses.mit;
    mainProgram = "cloakbrowser";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
