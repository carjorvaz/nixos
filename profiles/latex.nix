{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    texlive.combined.scheme-full
    texlab
    python310Packages.pygments # Needed for syntax highlighting in code blocks.
  ];
}
