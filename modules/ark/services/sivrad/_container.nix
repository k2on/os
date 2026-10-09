# Names, paths and addresses of the `sivrad` container that more than the
# guest needs: ./_guest.nix builds the container from them, ./_host.nix
# wires up its network, and ./default.nix hands some to `ark service
# sivrad` (./cli) through the arkServiceConfig.sivrad output and points the
# browser page's proxy on adam (sivrad-browser) at the container.
rec {
  # The container's name, which is also its hostname and its tailnet node
  # name.
  name = "sivrad";
  # The account Claude Code, signal-cli and the channel run as.
  user = "sivrad";
  home = "/var/lib/sivrad";
  # signal-cli's data directory (--config): the Signal account lives in
  # data/ under it.
  signalDir = "${home}/signal-cli";
  # The JSON-RPC socket of the signal-cli daemon.
  signalSocket = "/run/sivrad/signal.sock";
  # The veth link to adam (privateNetwork, ./_host.nix): adam's end and the
  # container's.
  hostAddress = "192.168.77.1";
  localAddress = "192.168.77.2";
  # The noVNC page of the headed browser (./_chrome.nix). Only adam reaches
  # it, over the veth: sivrad-browser there serves it to people behind a
  # Kanidm sign-in (./default.nix), at https://sivrad.<mainDomain> under
  # this path, which websockify serves it under too.
  novncPort = 6080;
  novncPrefix = "/browser";
}
