{ pkgs, ... }:

{
  programs.mpv = {
    enable = true;

    package = pkgs.mpv.override {
      scripts = with pkgs.mpvScripts; [
        sponsorblock-minimal
      ];
      mpv-unwrapped = pkgs.mpv-unwrapped.override {
        ffmpeg = pkgs.ffmpeg-full;
      };
    };

    config = {
      hwdec = "auto-safe";
      profile = "gpu-hq";
      vo = "gpu";
    };
  };
}
