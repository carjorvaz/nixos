_:

{
  services.syncthing = {
    enable = true;
    systemService = true;
    user = "cjv";
    group = "users";
    dataDir = "/home/cjv";
    configDir = "/home/cjv/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
    openDefaultPorts = true;
    overrideDevices = true;
    overrideFolders = true;

    settings = {
      # Reuse the Air's existing Syncthing identity so we can revive the old
      # Org share instead of creating yet another peer/folder lineage.
      devices.air = {
        id = "CO234N7-ZWONVE3-Q7YYPVR-WVQAULG-RU3WDKT-OJRV5EY-YSQTWVW-BUAAPAB";
        name = "air";
      };

      folders.org = {
        id = "mybuc-ckyui";
        label = "Org";
        path = "/home/cjv/org";
        # Preserve the local named ACL that gives Hermes access to this tree.
        ignorePerms = true;
        devices = [ "air" ];
        minDiskFree = {
          unit = "MiB";
          value = 256;
        };
        rescanIntervalS = 3600;
        fsWatcherEnabled = true;
        fsWatcherDelayS = 10;

        # Hot Org files like gtd.org and daily notes benefit from a local
        # recovery net on both read-write peers.
        versioning = {
          type = "staggered";
          cleanupIntervalS = 3600;
          fsPath = "";
          fsType = "basic";
          params.maxAge = "31536000";
        };
      };

      folders.nixos = {
        id = "nixos";
        label = "NixOS";
        path = "/home/cjv/sync/nixos";
        # Syncthing must not rewrite the named and inherited Hermes ACLs.
        ignorePerms = true;
        devices = [ "air" ];
        minDiskFree = {
          unit = "MiB";
          value = 256;
        };
        rescanIntervalS = 3600;
        fsWatcherEnabled = true;
        fsWatcherDelayS = 10;
        ignorePatterns = [
          "/.git"
          "/.jj"
          "/.claude"
          "/.direnv"
          "/.agent-backups"
          "/result"
          "/result-*"
          "*.log"
          "(?d).DS_Store"
        ];

        # Hermes edits flow back to Air; retain displaced and deleted versions
        # locally on both peers as a recovery layer below source control.
        versioning = {
          type = "staggered";
          cleanupIntervalS = 3600;
          fsPath = "";
          fsType = "basic";
          params.maxAge = "31536000";
        };
      };

      options = {
        localAnnounceEnabled = true;
        minHomeDiskFree = {
          unit = "MiB";
          value = 256;
        };
        relaysEnabled = true;
        urAccepted = -1;
        startBrowser = false;
      };
    };
  };
}
