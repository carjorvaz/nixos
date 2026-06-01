_:

{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    settings =
      let
        serverConf = {
          User = "root";
          SetEnv = {
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
}
