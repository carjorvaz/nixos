{ ... }:

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
      # Reuse the Mac's existing Syncthing identity so we can revive the old
      # Org share instead of creating yet another peer/folder lineage.
      devices.mac = {
        id = "CO234N7-ZWONVE3-Q7YYPVR-WVQAULG-RU3WDKT-OJRV5EY-YSQTWVW-BUAAPAB";
        name = "mac";
      };

      folders.org = {
        id = "mybuc-ckyui";
        label = "Org";
        path = "/home/cjv/org";
        devices = [ "mac" ];
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

      folders.tese = {
        id = "tese-sync";
        label = "Tese";
        path = "/home/cjv/Documents/tese";
        devices = [ "mac" ];
        minDiskFree = {
          unit = "MiB";
          value = 256;
        };
        rescanIntervalS = 3600;
        fsWatcherEnabled = true;
        fsWatcherDelayS = 10;

        # Thesis edits are high value, and this keeps a recoverable trail if a
        # bad sync or accidental save slips through.
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
