{
  pkgs,
  lib,
  config,
  ...
}:

{
  programs.helix = let theme = lib.attrByPath [ "graphical" "theme" "appNames" "helix" ] "gruvbox_dark_hard" config; in {
    enable = true;
    package = pkgs.evil-helix;

    settings = {
      theme = theme;

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
            command = "${pkgs.prettier}/bin/prettier";
            args = [
              "--parser"
              "html"
            ];
          };
        }
        {
          name = "json";
          formatter = {
            command = "${pkgs.prettier}/bin/prettier";
            args = [
              "--parser"
              "json"
            ];
          };
        }
        {
          name = "css";
          formatter = {
            command = "${pkgs.prettier}/bin/prettier";
            args = [
              "--parser"
              "css"
            ];
          };
        }
        {
          name = "javascript";
          formatter = {
            command = "${pkgs.prettier}/bin/prettier";
            args = [
              "--parser"
              "typescript"
            ];
          };
        }
        {
          name = "typescript";
          formatter = {
            command = "${pkgs.prettier}/bin/prettier";
            args = [
              "--parser"
              "typescript"
            ];
          };
        }
        {
          name = "markdown";
          formatter = {
            command = "${pkgs.prettier}/bin/prettier";
            args = [
              "--parser"
              "markdown"
            ];
          };
        }
        {
          name = "nix";
          auto-format = true;
          formatter.command = "${pkgs.nixfmt}/bin/nixfmt";
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
          command = "ruff";
          args = [ "server" ];

          config.settings.lineLength = 100;
        };
      };
    };
  };
}
