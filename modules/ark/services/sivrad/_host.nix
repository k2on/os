# Host side of the `sivrad` container (systemd-nspawn, via NixOS
# containers): a veth link to the guest, NAT, and an egress policy. The
# guest itself is described in ./_guest.nix.
#
# Policy for traffic from the container (blocked packets are logged with the
# prefix "sivrad-drop: ", allowed web connections with "sivrad-egress: "):
#   - to adam itself: only TCP 443 (nginx) and 8123 (Home Assistant);
#   - forwarded: DNS and the web (TCP 80 and 443, so the model's browser
#     reaches any public website) to public addresses, nothing to the LAN,
#     the tailnet, or link-local ranges; no IPv6 at all.
#   - tailscale: UDP 41641 anywhere, any other UDP to public addresses
#     (STUN, peers). Once the container is on the tailnet its traffic there
#     is WireGuard, so what it may reach on the tailnet is up to headscale's
#     ACL, not to this chain.
# Traffic from adam to the container is not filtered here: oauth2-proxy
# (sivrad-browser, ./default.nix) connects to the browser's noVNC page on
# localAddress, and the container's answers pass sivrad-in as ESTABLISHED.
# The guest's own firewall lets only adam's address in on that port
# (./_chrome.nix).
# The rules live in the mangle table because tailscaled inserts its own
# ts-forward chain (which ACCEPTs everything leaving via tailscale0) at the
# top of filter/FORWARD after the NixOS firewall has started.
{ config, lib, ... }:
let
  # The host end of the container's veth pair, named by nixos-containers.
  veth = "ve-sivrad";
  # Directory bind-mounted read-only into the guest, so the guest needs no
  # sops of its own. It holds a copy of adam's tailnet pre-auth key
  # (den.aspects.tailnet), root-only, and the saved Signal account
  # signal-account.tar.gz.b64 (sivrad_signal_account, empty until one is
  # saved), world-readable for signal-cli, which runs as `sivrad`. The
  # directory is 0711: no listing. The container shares the host's UIDs
  # (privateUsers = "no"), so ownership passes straight through.
  credentialsDir = "/run/sivrad-credentials";
  bot = import ./_bot.nix;
  container = import ./_container.nix;
  hostPorts = [
    443
    8123
  ];
  privateRanges = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "100.64.0.0/10"
    "169.254.0.0/16"
  ];

  # Remove our hooks and chains; safe to run when they do not exist.
  teardown = ''
    iptables -w -t mangle -D FORWARD -i ${veth} -j sivrad-fwd 2>/dev/null || true
    iptables -w -t mangle -D INPUT -i ${veth} -j sivrad-in 2>/dev/null || true
    ip6tables -w -t mangle -D FORWARD -i ${veth} -j DROP 2>/dev/null || true
    ip6tables -w -t mangle -D INPUT -i ${veth} -j DROP 2>/dev/null || true
    for chain in sivrad-fwd sivrad-in sivrad-drop; do
      iptables -w -t mangle -F $chain 2>/dev/null || true
      iptables -w -t mangle -X $chain 2>/dev/null || true
    done
  '';
in
{
  containers.sivrad = {
    autoStart = true;
    # A rebuild of adam restarts the container when its configuration
    # changed, so a deploy is the whole upgrade. That ends the running
    # Claude session; its workspace, login and the Signal account persist,
    # so a conversation only loses what was in flight.
    restartIfChanged = true;
    # Its own network namespace, on a veth to adam; addresses and the
    # default route are set by nixos-containers on both ends.
    privateNetwork = true;
    inherit (container) hostAddress localAddress;
    # tailscaled in the guest needs /dev/net/tun and CAP_NET_ADMIN.
    enableTun = true;
    bindMounts."/run/host-credentials" = {
      hostPath = credentialsDir;
      isReadOnly = true;
    };
    # The sivrad account's Kanidm password and the API tokens the services
    # minted for it (./_bot.nix, <service>/_tokens.nix), for the model to
    # read as /run/host-tokens/<name>. Unlike the credentials above these
    # are meant for it, so the guest does not hide them.
    bindMounts."/run/host-tokens" = {
      hostPath = bot.tokensDir;
      isReadOnly = true;
    };
    # Evaluated as its own NixOS system (nixos-containers only passes the
    # host platform on), so the claude-code unfree allowance stays scoped
    # to the guest (see _guest.nix).
    config.imports = [ ./_guest.nix ];
  };

  # Refresh the guest's copies before the container starts. In the guest
  # the key is root:root 0400 and invisible to the `sivrad` user. Managed
  # settings keep the model away from all of /run/host-credentials.
  systemd.services.sivrad-credentials = {
    description = "Credentials for the sivrad container";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0711 -o root -g root ${credentialsDir}
      chmod 0711 ${credentialsDir}
      chown root:root ${credentialsDir}
      install -m 0400 -o root -g root ${config.sops.secrets.headscale_preauth_key.path} ${credentialsDir}/headscale_preauth_key
      install -m 0444 -o root -g root ${config.sops.secrets.sivrad_signal_account.path} ${credentialsDir}/signal-account.tar.gz.b64
      # The account's files (./_kanidm.nix and the services fill it) must
      # exist for the bind mount below.
      install -d -m 0711 -o root -g root ${bot.tokensDir}
    '';
  };
  systemd.services."container@sivrad" = {
    requires = [ "sivrad-credentials.service" ];
    after = [ "sivrad-credentials.service" ];
  };

  # The guest's firewall tells local connections apart by user (`-m owner`,
  # ./_chrome.nix), and a container cannot load kernel modules itself.
  boot.kernelModules = [ "xt_owner" ];

  # No externalInterface: masquerade on whichever interface the route picks.
  networking.nat = {
    enable = true;
    internalInterfaces = [ veth ];
  };

  # Open the ports in nixos-fw; sivrad-in below closes everything else
  # (adam's global allowedTCPPorts would otherwise also apply to the
  # container).
  networking.firewall.interfaces.${veth}.allowedTCPPorts = hostPorts;

  networking.firewall.extraCommands = teardown + ''
    iptables -w -t mangle -N sivrad-drop
    iptables -w -t mangle -A sivrad-drop -m limit --limit 10/min -j LOG --log-prefix "sivrad-drop: "
    iptables -w -t mangle -A sivrad-drop -j DROP

    iptables -w -t mangle -N sivrad-in
    iptables -w -t mangle -A sivrad-in -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -w -t mangle -A sivrad-in -p tcp -m multiport --dports ${
      lib.concatMapStringsSep "," toString hostPorts
    } -j RETURN
    iptables -w -t mangle -A sivrad-in -j sivrad-drop

    iptables -w -t mangle -N sivrad-fwd
    iptables -w -t mangle -A sivrad-fwd -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -w -t mangle -A sivrad-fwd -p udp --dport 53 -j RETURN
    iptables -w -t mangle -A sivrad-fwd -p tcp --dport 53 -j RETURN
    iptables -w -t mangle -A sivrad-fwd -p udp --dport 41641 -j RETURN
    ${lib.concatMapStringsSep "\n" (
      range: "iptables -w -t mangle -A sivrad-fwd -d ${range} -j sivrad-drop"
    ) privateRanges}
    iptables -w -t mangle -A sivrad-fwd -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -m limit --limit 10/min -j LOG --log-prefix "sivrad-egress: "
    iptables -w -t mangle -A sivrad-fwd -p tcp -m multiport --dports 80,443 -j RETURN
    iptables -w -t mangle -A sivrad-fwd -p udp -j RETURN
    iptables -w -t mangle -A sivrad-fwd -j sivrad-drop

    iptables -w -t mangle -I INPUT 1 -i ${veth} -j sivrad-in
    iptables -w -t mangle -I FORWARD 1 -i ${veth} -j sivrad-fwd
    ip6tables -w -t mangle -I INPUT 1 -i ${veth} -j DROP
    ip6tables -w -t mangle -I FORWARD 1 -i ${veth} -j DROP
  '';
  networking.firewall.extraStopCommands = teardown;
}
