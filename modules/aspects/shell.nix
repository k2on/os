# The same zsh on every host: vi keys, and a prompt in the host's colour
# (den.hosts.<…>.color, lib/host-schema.nix), so a terminal on adam never
# looks like one on cale. System-wide, so it is everyone's: the Kanidm
# accounts on the servers (aspects/login.nix gives them zsh) as well as the
# laptop's own, whose home-manager zsh adds to it.
# The colours so far (Catppuccin): adam #a6e3a1 light green, benj #fab387
# orange, cale #f9e2af yellow, dani #cba6f7 mauve (once it is a host), ephr
# #40a02b dark green.
{ den, lib, ... }:
{
  den.default.includes = [
    (
      { host, ... }:
      lib.optionalAttrs (host ? class && host.class == "nixos") {
        nixos =
          let
            color = if host.color == null then "default" else host.color;
          in
          {
            programs.zsh = {
              enable = true;
              # zsh offers to write a ~/.zshrc for a home without one, such
              # as a Kanidm account's on its first login; this is it.
              shellInit = ''
                zsh-newuser-install() { :; }
              '';
              interactiveShellInit = ''
                bindkey -v
                # Esc goes to normal mode at once, not after 0.4 s.
                export KEYTIMEOUT=1
              '';
              # user@host in the host's colour, then where you are, the last
              # command's status when it failed, and # as root.
              promptInit = ''
                setopt prompt_sp prompt_subst
                PROMPT='%B%F{${color}}%n@%m%f%b %F{blue}%~%f %(?..%F{red}[%?]%f )%(!.#.$) '
              '';
            };
          };
      }
    )
  ];
}
