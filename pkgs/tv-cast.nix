{ writeShellApplication, yt-dlp, miniserve, android-tools, tailscale, libnotify, python3 }:

writeShellApplication {
  name = "tv";

  runtimeInputs = [ yt-dlp miniserve android-tools tailscale libnotify python3 ];

  text = ''
    cleanup() {
      [ -n "''${srv_pid:-}" ] && kill "$srv_pid" 2>/dev/null
      [ -n "''${tmpdir:-}" ] && rm -rf "$tmpdir"
    }
    trap cleanup EXIT

    url="''${1:?Usage: tv <youtube-url>}"

    case "$url" in
      tv://*)
        url="$(printf '%s' "$url" | sed 's|^tv://||' | python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))')"
        ;;
    esac

    port=9090
    ts_ip=$(tailscale ip -4)
    tmpdir=$(mktemp -d /tmp/tv-XXXXXX)
    tmpfile="$tmpdir/video.mp4"

    pkill -f "miniserve.*$port" 2>/dev/null || true

    echo "Downloading..."
    yt-dlp --cookies-from-browser firefox \
      -f 'bv+ba/b' \
      --sponsorblock-remove default \
      --merge-output-format mp4 \
      -o "$tmpfile" "$url"

    echo "Serving on $ts_ip:$port"
    miniserve -p "$port" "$tmpdir" &
    srv_pid=$!
    sleep 0.5

    adb connect sony-bravia-bf1
    adb shell am start -a android.intent.action.VIEW \
      -d "http://$ts_ip:$port/video.mp4" \
      -t "video/mp4"

    notify-send -u low "TV" "Now playing"
    echo "Playing on TV - Ctrl-C to stop"
    wait "$srv_pid"
  '';
}
