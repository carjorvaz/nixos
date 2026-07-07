{
  lib,
  python3Packages,
}:

python3Packages.buildPythonApplication rec {
  pname = "cloakbrowser";
  version = "0.4.8";
  pyproject = true;

  src = python3Packages.fetchPypi {
    inherit pname version;
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
    description = "Stealth Chromium wrapper and CLI for Playwright automation";
    homepage = "https://github.com/CloakHQ/CloakBrowser";
    license = lib.licenses.mit;
    mainProgram = "cloakbrowser";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
