# A terminal to work in, for a person whose home includes it: zsh (vi keys,
# Ctrl+G to jump between projects in ~/dev), tmux, lf, the starship prompt,
# direnv, and Codex (./codex.nix, with their own Tinfoil key). Each file
# here adds to den.aspects.terminal's homeManager; the terminal emulator
# itself is every desktop's (aspects/gui/home).
{ ... }:
{
  den.aspects.terminal = { };
}
