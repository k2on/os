# Names, paths, users and addresses of the `sivrad` container that more than
# the guest needs: ./_guest.nix and the files it imports build the container
# from them, ./_host.nix wires up its network, and ./default.nix hands some
# to `ark service sivrad` (./cli) through the arkServiceConfig.sivrad output
# and points the browser page's proxy on adam (sivrad-browser) at the
# container.
rec {
  # The container's name, which is also its hostname and its tailnet node
  # name.
  name = "sivrad";
  # Three accounts, so that what the agent's shell commands may read is a
  # matter of file permissions (it runs them as itself, with no sandbox):
  #   - `sivrad`: the agent (Codex, ./_codex.nix), its home and workspace;
  #   - `sivrad-channel`: signal-cli and the channel (./_guest.nix), which
  #     hold the Signal account and its socket; also the account `ark
  #     service sivrad` logs in as over ssh;
  #   - `sivrad-browser`: the headed browser and its screen (./_chrome.nix),
  #     whose profile holds people's sign-ins.
  # The agent reaches the other two over loopback only: the channel's MCP
  # endpoint and the browser's DevTools port; the channel reaches the agent
  # over its socket.
  user = "sivrad";
  channelUser = "sivrad-channel";
  browserUser = "sivrad-browser";
  home = "/var/lib/sivrad";
  # The agent's workspace: its files, the inbox for files received over
  # Signal, the browser's downloads. Group `sivrad`, which the other two
  # accounts are in, may read and write it.
  workspace = "${home}/workspace";
  channelHome = "/var/lib/${channelUser}";
  browserHome = "/var/lib/${browserUser}";
  # ssh user for `ark service sivrad ...`: the channel's, which owns the
  # Signal account.
  sshUser = channelUser;
  # signal-cli's data directory (--config): the Signal account lives in
  # data/ under it.
  signalDir = "${channelHome}/signal-cli";
  # The JSON-RPC socket of the signal-cli daemon.
  signalSocket = "/run/${channelUser}/signal.sock";
  # The veth link to adam (privateNetwork, ./_host.nix): adam's end and the
  # container's.
  hostAddress = "192.168.77.1";
  localAddress = "192.168.77.2";
  # Loopback ports. The LLM side (./_llm.nix): Tinfoil's attesting proxy,
  # and sivrad-llm in front of it, which is what the agent talks to. The
  # channel's MCP endpoint, which the agent calls back on. The browser's
  # DevTools port (./_chrome.nix), which the agent drives it by.
  ports = {
    tinfoil = 3301;
    llm = 4000;
    mcp = 8789;
    cdp = 9222;
  };
  # The agent's app-server socket (./_codex.nix): systemd listens as the
  # agent, the channel connects.
  codexSocket = "/run/sivrad/codex.sock";
  # The channel's HTTP port for the phone, on the tailnet.
  phonePort = 8788;
  # The noVNC page of the headed browser (./_chrome.nix). Only adam reaches
  # it, over the veth: sivrad-browser there serves it to people behind a
  # Kanidm sign-in (./default.nix), at https://sivrad.<mainDomain> under
  # this path, which websockify serves it under too.
  novncPort = 6080;
  novncPrefix = "/browser";
}
