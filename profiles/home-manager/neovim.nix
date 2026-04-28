{ ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    withPython3 = true;
    withRuby = true;
    initLua = ''
      vim.cmd.colorscheme 'vim'
      vim.opt.clipboard:append 'unnamedplus'
    '';
  };
}
