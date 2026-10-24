{ ... }:

{
  # YouTube's EJS challenge solver needs both a JS runtime and the solver
  # scripts. yt-dlp enables deno by default, which air does not have; Homebrew's
  # node is already on PATH. Allow the pinned scripts to be fetched from GitHub
  # when the installed yt-dlp lacks the yt-dlp-ejs package.
  # The module also installs yt-dlp, which resolves to the same store path as the
  # system package, so this costs no extra download.
  programs.yt-dlp = {
    enable = true;
    settings = {
      js-runtimes = "node";
      remote-components = "ejs:github";
    };
  };
}
