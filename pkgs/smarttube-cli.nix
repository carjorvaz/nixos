{ writeShellApplication, android-tools, libnotify, python3 }:

writeShellApplication {
  name = "smarttube";

  runtimeInputs = [ android-tools libnotify python3 ];

  text = ''
    url="$1"

    # Handle protocol handler case: remove prefix and decode
    case "$url" in
      smarttube://*)
        url="$(printf '%s' "$url" | sed 's|^smarttube://||' | python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))')"
        ;;
    esac

    adb connect sony-bravia-bf1
    adb shell am start -a android.intent.action.VIEW -d "\"$url\"" org.smarttube.beta

    notify-send -u low "SmartTube" "Sent to TV"
  '';
}
