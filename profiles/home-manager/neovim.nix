{ ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    initLua = ''
      vim.opt.clipboard:append 'unnamedplus'
    '';
  };
}
