{ writeShellApplication, libnotify, python3 }:

writeShellApplication {
  name = "org-dump";

  runtimeInputs = [ libnotify python3 ];

  text = ''
    input="$1"

    # Handle protocol handler case: org-dump://<description>?url=<encoded_url>
    case "$input" in
      org-dump://*)
        input="$(printf '%s' "$input" | sed 's|^org-dump://||')"
        ;;
    esac

    # Split on ?url= and decode both parts
    description="$(printf '%s' "$input" | sed 's|?url=.*||' | python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))')"
    url="$(printf '%s' "$input" | sed 's|.*?url=||' | python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))')"

    # Find the most recent daily file using glob (safer than parsing ls)
    daily_dir="$HOME/org/roam/daily"
    latest_daily="$(printf '%s\n' "$daily_dir"/*.org 2>/dev/null | sort -r | head -1)"

    if [ -z "$latest_daily" ] || [ "$latest_daily" = "$daily_dir/*.org" ]; then
      notify-send -u critical "Org Dump" "No daily file found in $daily_dir"
      exit 1
    fi

    # Append heading with description and URL to the file
    printf '* %s %s\n' "$description" "$url" >> "$latest_daily"

    notify-send -u low "Org Dump" "Saved to $(basename "$latest_daily")"
  '';
}
