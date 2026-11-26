# Who may sign in at a desktop: besides the admins every host lets in
# (aspects/defaults/login.nix), the members of ark.login.desktop.group (the
# family), with their Kanidm POSIX password, and no sudo. Their home is
# made on their first sign-in, /home/<uuid> with /home/<name> beside it.
{ config, ... }:
{
  den.aspects.gui.nixos.services.kanidm.unix.settings.kanidm.pam_allowed_login_groups = [
    config.ark.login.desktop.group
  ];
}
