{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    helix
    basedpyright
    ruff
    nodePackages.prettier
  ];

  home-manager.users.cjv = {
    programs.helix = {
      enable = true;
      # package = pkgs.evil-helix;

      settings = {
        theme = "gruvbox_dark_hard";

        editor = {
          file-picker.hidden = false;
          line-number = "relative";

          cursor-shape = {
            normal = "block";
            insert = "bar";
            select = "underline";
          };
        };

        keys.insert."C-[" = "normal_mode";
      };

      languages = {
        language = [
          {
            name = "html";
            formatter = {
              command = "${pkgs.nodePackages.prettier}/bin/nodePackages.prettier";
              args = [
                "--parser"
                "html"
              ];
            };
          }
          {
            name = "json";
            formatter = {
              command = "${pkgs.nodePackages.prettier}/bin/nodePackages.prettier";
              args = [
                "--parser"
                "json"
              ];
            };
          }
          {
            name = "css";
            formatter = {
              command = "${pkgs.nodePackages.prettier}/bin/nodePackages.prettier";
              args = [
                "--parser"
                "css"
              ];
            };
          }
          {
            name = "javascript";
            formatter = {
              command = "${pkgs.nodePackages.prettier}/bin/nodePackages.prettier";
              args = [
                "--parser"
                "typescript"
              ];
            };
          }
          {
            name = "typescript";
            formatter = {
              command = "${pkgs.nodePackages.prettier}/bin/nodePackages.prettier";
              args = [
                "--parser"
                "typescript"
              ];
            };
          }
          {
            name = "markdown";
            formatter = {
              command = "${pkgs.nodePackages.prettier}/bin/nodePackages.prettier";
              args = [
                "--parser"
                "markdown"
              ];
            };
          }
          {
            name = "nix";
            auto-format = true;
            formatter.command = "${pkgs.nixfmt-rfc-style}/bin/nixfmt";
          }
          {
            name = "python";
            auto-format = true;
            language-servers = [
              "basedpyright"
              "ruff"
            ];
          }
        ];

        language-server = {
          basedpyright.config.basedpyright.analysis.typeCheckingMode = "basic";

          ruff = {
            comman = "ruff";
            args = [ "server" ];

            config.settings.lineLength = 100;
          };
        };
      };
    };
  };
}
