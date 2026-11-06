# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# Stalwart's settings for ark's mail, shared by the server (./default.nix)
# and the end-to-end check (./_check.nix) so the check runs what benj runs.
#
#   domains = [ the domains mail is delivered here for ];
#   listen  = { smtp = "[::]:25"; submissions = "[::]:465"; imaps = "[::]:993"; };
#   relay   = null | { address; port; usernameFile; passwordFile; };
#
# Everything is read from this file (config.local-keys = *), so nothing can
# drift in Stalwart's database. Accounts are its in-memory directory, whose
# entries `mail-aliases render` (./aliases) appends when Stalwart starts:
# people log in by name (not address, which changes when the domain does;
# the name keeps the mailbox). A group is a shared mailbox: its members see
# it under "Shared Folders/<name>" in their own account and may send as
# its address and its aliases; a person may send as their own aliases, so
# a reply goes out from the address it came to.
#
# With a relay, mail for anywhere but these domains leaves through it (TEM,
# over TLS from the first byte, which a port the vps's provider leaves open
# allows), and the relay signs it: Stalwart signs nothing itself. Without
# one it goes straight to the recipient's server.
{
  hostname,
  domains,
  listen,
  certFile,
  keyFile,
  spamFilter,
  relay ? null,
}:
let
  isLocal = builtins.concatStringsSep " || " (map (d: "rcpt_domain == '${d}'") domains);
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
  directory.ark.type = "memory";

  # Only people with an account may send through it.
  session.rcpt.relay = [
    {
      "if" = "!is_empty(authenticated_as)";
      "then" = true;
    }
    { "else" = false; }
  ];

  spam-filter.resource = spamFilter;

  auth.dkim.sign = false;

  queue = {
    # Our domains by name: Stalwart's own is_local_domain() only knows a
    # domain once it has looked up an account in it.
    strategy.route = [
      {
        "if" = isLocal;
        "then" = "'local'";
      }
      { "else" = if relay == null then "'mx'" else "'relay'"; }
    ];
  }
  // (
    if relay == null then
      { }
    else
      {
        route.relay = {
          type = "relay";
          inherit (relay) address port;
          protocol = "smtp";
          tls.implicit = true;
          auth.username = "%{file:${relay.usernameFile}}%";
          auth.secret = "%{file:${relay.passwordFile}}%";
        };
      }
  );
}
