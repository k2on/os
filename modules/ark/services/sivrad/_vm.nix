# Names and paths of the `sivrad` microVM that more than the guest needs:
# ./_guest.nix builds the VM from them, ./default.nix hands them to
# `ark service sivrad` (./cli) through the arkServiceConfig.sivrad output.
rec {
  # The VM's name, which is also its hostname and its tailnet node name.
  name = "sivrad";
  # The account Claude Code, signal-cli and the channel run as.
  user = "sivrad";
  home = "/var/lib/sivrad";
  # signal-cli's data directory (--config): the Signal account lives in
  # data/ under it.
  signalDir = "${home}/signal-cli";
  # The JSON-RPC socket of the signal-cli daemon.
  signalSocket = "/run/sivrad/signal.sock";
  # The VM's ed25519 ssh host key, on a volume of its own so a rebuilt VM
  # keeps the identity `ark service sivrad` knows it by over ssh.
  sshDir = "/var/lib/ssh";
}
