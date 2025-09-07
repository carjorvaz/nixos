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
          julius = serverConf;
          pius = serverConf;
          trajanus = serverConf;
        };
    };
  };
}
