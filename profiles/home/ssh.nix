{ ... }:

{
  home-manager.users.cjv = {
    programs.ssh = {
      enable = true;

      matchBlocks =
        let
          serverConf = {
            user = "root";
            setEnv = {
              TERM = "xterm-256color";
            };
          };
        in
        {
          hadrianus = serverConf;
          pius = serverConf;
          t440 = serverConf;
        };
    };
  };
}
