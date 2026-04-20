{ ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    withPython3 = true;
    withRuby = true;
    initLua = ''
      vim.opt.clipboard:append 'unnamedplus'
    '';
  };
}
