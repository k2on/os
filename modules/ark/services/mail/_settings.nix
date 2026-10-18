# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# Stalwart's settings for ark's mail, shared by the server (./default.nix)
# and the end-to-end check (./_check.nix) so the check runs what benj runs.
#
#   mailboxes = [ { name; address; passwordFile; memberOf = [ <shared> ]; } ];
#   shared    = [ { name; address; } ];
#   listen    = { smtp = "[::]:25"; submissions = "[::]:465"; imaps = "[::]:993"; };
#
# Everything is read from this file (config.local-keys = *), so nothing can
# drift in Stalwart's database. Accounts are its in-memory directory, built
# from the above on every start: a person logs in by name (not address, which
# changes when the domain does; the name keeps the mailbox) with
# the password in their passwordFile. A shared mailbox is a Stalwart group;
# its members see it under "Shared Folders/<name>" in their own account and
# may send as its address.
{
  hostname,
  mailboxes,
  shared,
  listen,
  certFile,
  keyFile,
  spamFilter,
}:
let
  sharedAddress = builtins.listToAttrs (
    map (s: {
      inherit (s) name;
      value = s.address;
    }) shared
  );
in
{
  config.local-keys = [ "*" ];

  server = {
    inherit hostname;
    listener = {
      smtp = {
        protocol = "smtp";
        bind = [ listen.smtp ];
      };
      submissions = {
        protocol = "smtp";
        bind = [ listen.submissions ];
        tls.implicit = true;
      };
      imaps = {
        protocol = "imap";
        bind = [ listen.imaps ];
        tls.implicit = true;
      };
    };
  };

  certificate.default = {
    cert = "%{file:${certFile}}%";
    private-key = "%{file:${keyFile}}%";
    default = true;
  };

  storage.directory = "ark";
  directory.ark = {
    type = "memory";
    # Groups first: an address listed on several principals goes to the
    # first, so mail to a shared address lands in the group's mailbox. Its
    # members carry it too, as an alias, which is what lets them send as it:
    # Stalwart looks a group's own addresses up in its internal directory,
    # not this one, so membership alone does not.
    principals =
      map (s: {
        class = "group";
        inherit (s) name;
        email = [ s.address ];
      }) shared
      ++ map (m: {
        class = "individual";
        inherit (m) name;
        secret = "%{file:${m.passwordFile}}%";
        email = [ m.address ] ++ map (g: sharedAddress.${g}) m.memberOf;
        member-of = m.memberOf;
      }) mailboxes;
  };

  # Only people with an account may send through it.
  session.rcpt.relay = [
    {
      "if" = "!is_empty(authenticated_as)";
      "then" = true;
    }
    { "else" = false; }
  ];

  spam-filter.resource = spamFilter;
}
