# Names, addresses and paths of the `sivrad` microVM that more than the
# guest needs: ./_guest.nix builds the VM from them, ./_host.nix and
# ./default.nix set up adam's side of the link, and ./default.nix hands some
# to `ark service sivrad` (./cli) through the arkServiceConfig.sivrad output.
rec {
  # The VM's name, which is also its hostname and its tailnet node name.
  name = "sivrad";
  # The account Claude Code, signal-cli and the channel run as.
  user = "sivrad";
  home = "/var/lib/sivrad";
  # The tap link between adam and the VM (a /24).
  hostAddress = "192.168.77.1";
  address = "192.168.77.2";
  # The channel's HTTP port, on the VM's tap address; adam's nginx proxies
  # https://sivrad.<mainDomain> to it.
  channelPort = 8788;
  # signal-cli's data directory (--config): the Signal account lives in
  # data/ under it.
  signalDir = "${home}/signal-cli";
  # The JSON-RPC socket of the signal-cli daemon.
  signalSocket = "/run/sivrad/signal.sock";
}
