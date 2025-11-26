{ ... }:

{
  home-manager.users.cjv = {
    programs.neovim = {
      enable = true;
      vimAlias = true;
      extraLuaConfig = ''
        vim.opt.clipboard:append 'unnamedplus'
      '';
    };
  };
}
