{
  writeShellApplication,
  writeText,
  callPackage,
  libnotify,
  python3,
}:

let
  orgDailyScratch = callPackage ./org-daily-scratch.nix { };
  script = writeText "org-dump.py" ''
    #!/usr/bin/env python3
    import subprocess
    import sys
    import urllib.parse

    def notify(urgency, title, body):
        try:
            subprocess.run(
                ["notify-send", "-u", urgency, title, body],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            pass

    def parse_input(raw):
        if raw.startswith("org-dump://"):
            raw = raw[len("org-dump://"):]
        if "?url=" in raw:
            description, url = raw.split("?url=", 1)
        else:
            description, url = raw, ""
        description = urllib.parse.unquote(description).strip()
        url = urllib.parse.unquote(url).strip()
        return description, url

    def main():
        if len(sys.argv) < 2 or not sys.argv[1].strip():
            notify("critical", "Org Dump", "No description or URL provided")
            return 1

        description, url = parse_input(sys.argv[1])
        text = description or url
        if not text:
            notify("critical", "Org Dump", "No description or URL provided")
            return 1

        cmd = ["org-daily-scratch", "--source", "org-dump"]
        if url:
            cmd.extend(["--link", url, "--heading", text])
        else:
            cmd.extend(["--", text])

        result = subprocess.run(cmd, text=True, capture_output=True)
        if result.returncode != 0:
            message = (result.stderr or result.stdout or "org-daily-scratch failed").strip()
            notify("critical", "Org Dump", message[:200])
            sys.stderr.write(result.stderr)
            sys.stdout.write(result.stdout)
            return result.returncode

        notify("low", "Org Dump", "Saved to today's Workbench/Scratch")
        sys.stdout.write(result.stdout)
        return 0

    if __name__ == "__main__":
        raise SystemExit(main())
  '';
in
writeShellApplication {
  name = "org-dump";

  runtimeInputs = [
    libnotify
    python3
    orgDailyScratch
  ];

  text = ''
    exec python3 ${script} "$@"
  '';
}
