{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  sshKeys = import ./ssh-keys.nix;
  llmClusterIp = pkgs.writeShellApplication {
    name = "llm-cluster-ip";
    runtimeInputs = [
      config.systemd.package
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.networkmanager
    ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
Usage:
  llm-cluster-ip OCTET [CIDR] [IFACE]

Set a temporary static address and readable hostname for the LLM cluster lab fabric.

Examples:
  llm-cluster-ip 11
  llm-cluster-ip 11 10.42.0.11/24
  llm-cluster-ip 11 10.42.0.11/24 enx001122334455
EOF
      }

      if [[ "''${1:-}" == "-h" || "''${1:-}" == "--help" ]]; then
        usage
        exit 0
      fi

      octet="''${1:?missing OCTET; run llm-cluster-ip --help}"
      if [[ ! "$octet" =~ ^[0-9]+$ || "$octet" -lt 1 || "$octet" -gt 254 ]]; then
        echo "OCTET must be an integer from 1 to 254" >&2
        exit 1
      fi

      cidr="''${2:-10.42.0.$octet/24}"
      iface="''${3:-}"
      addr="''${cidr%/*}"
      node_name="llm-node-$octet"

      if [[ -z "$iface" ]]; then
        for path in /sys/class/net/*; do
          candidate="''${path##*/}"
          case "$candidate" in
            lo|wl*|ww*|docker*|br-*|virbr*|tailscale*|zt*) continue ;;
          esac
          if [[ -e "$path/carrier" ]] && grep -qx 1 "$path/carrier"; then
            iface="$candidate"
            break
          fi
        done
      fi

      if [[ -z "$iface" ]]; then
        echo "could not find a wired interface with carrier; pass IFACE explicitly" >&2
        echo "available interfaces:" >&2
        ip -brief link show >&2
        exit 1
      fi

      hostnamectl set-hostname "$node_name" 2>/dev/null || \
        printf '%s\n' "$node_name" > /proc/sys/kernel/hostname || true
      nmcli device set "$iface" managed no >/dev/null 2>&1 || true
      nmcli device disconnect "$iface" >/dev/null 2>&1 || true
      ip link set dev "$iface" up
      ip addr flush dev "$iface"
      ip addr add "$cidr" dev "$iface"
      ip -brief addr show dev "$iface"
      printf 'node: %s\n' "$node_name"
      printf 'ssh: ssh root@%s\n' "$addr"
    '';
  };
  llmClusterAutonet = pkgs.writeShellApplication {
    name = "llm-cluster-autonet";
    runtimeInputs = [
      llmClusterIp
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      set -euo pipefail

      octet=11
      cidr=

      read -ra cmdline < /proc/cmdline
      for token in "''${cmdline[@]}"; do
        case "$token" in
          llm.octet=*) octet="''${token#*=}" ;;
          llm.cidr=*) cidr="''${token#*=}" ;;
        esac
      done

      for _ in $(seq 1 60); do
        for path in /sys/class/net/*; do
          iface="''${path##*/}"
          case "$iface" in
            lo|wl*|ww*|docker*|br-*|virbr*|tailscale*|zt*|ip6tnl*) continue ;;
          esac
          if [[ -e "$path/carrier" ]] && grep -qx 1 "$path/carrier"; then
            args=("$octet" "''${cidr:-10.42.0.$octet/24}")
            args+=("$iface")
            exec llm-cluster-ip "''${args[@]}"
          fi
        done
        sleep 2
      done

      echo "llm-cluster-autonet: no wired carrier found; leaving lab address unconfigured"
    '';
  };
in
{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    ./llm-cluster-worker.nix
  ];

  # The installer ISO module sets a nixos-minimal basename internally.
  image.baseName = lib.mkForce "llm-cluster-live-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";

  boot.zfs.forceImportRoot = false;

  networking = {
    hostName = "llm-cluster-live";
    useDHCP = lib.mkDefault true;
    networkmanager.enable = lib.mkDefault true;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = [
    llmClusterAutonet
    llmClusterIp
    pkgs.git
    pkgs.jq
    pkgs.neovim
    pkgs.rsync
    pkgs.tcpdump
    pkgs.tmux
  ];

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      UseDns = false;
    };
  };

  systemd.services.llm-cluster-autonet = {
    description = "Auto-configure temporary direct-link LLM cluster address";
    wantedBy = [ "multi-user.target" ];
    after = [
      "NetworkManager.service"
      "systemd-udev-settle.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe llmClusterAutonet;
    };
  };

  users.users = {
    root.openssh.authorizedKeys.keys = sshKeys;
    nixos.openssh.authorizedKeys.keys = sshKeys;
  };
}
