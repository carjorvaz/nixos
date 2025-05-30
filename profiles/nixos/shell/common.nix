{ ... }:

{
  programs = {
    fzf = {
      fuzzyCompletion = true;
      keybindings = true;
    };

    starship.enable = true;

    zoxide.enable = true;
  };
}
