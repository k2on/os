# Host side of the `assistant` microVM: a tap link to the guest, NAT, and an
# egress policy. The guest itself is described in ./guest.nix.
#
# Policy for traffic from the VM (blocked packets are logged with the prefix
# "assistant-drop: ", allowed HTTPS with "assistant-egress: "):
#   - to adam itself: only TCP 443 (nginx) and 8123 (Home Assistant);
#   - forwarded: DNS and TCP 443 to public addresses, nothing to the LAN,
#     the tailnet, or link-local ranges; no IPv6 at all.
# The rules live in the mangle table because tailscaled inserts its own
# ts-forward chain (which ACCEPTs everything leaving via tailscale0) at the
# top of filter/FORWARD after the NixOS firewall has started.
{ lib, ... }:
let
  tap = "vm-assistant";
  hostAddress = "192.168.77.1";
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
    iptables -w -t mangle -D FORWARD -i ${tap} -j assistant-fwd 2>/dev/null || true
    iptables -w -t mangle -D INPUT -i ${tap} -j assistant-in 2>/dev/null || true
    ip6tables -w -t mangle -D FORWARD -i ${tap} -j DROP 2>/dev/null || true
    ip6tables -w -t mangle -D INPUT -i ${tap} -j DROP 2>/dev/null || true
    for chain in assistant-fwd assistant-in assistant-drop; do
      iptables -w -t mangle -F $chain 2>/dev/null || true
      iptables -w -t mangle -X $chain 2>/dev/null || true
    done
  '';
in
{
  microvm.vms.assistant = {
    # Rebuilding adam must not kill a running conversation; restart the VM
    # by hand (`systemctl restart microvm@assistant`) to pick up changes.
    restartIfChanged = false;
    # Build the guest from its own nixpkgs instance so the claude-code
    # unfree allowance stays scoped to the VM (see guest.nix).
    pkgs = null;
    config.imports = [ ./guest.nix ];
  };

  # The tap device is created by microvm-tap-interfaces@assistant.service;
  # scripted networking binds network-addresses-vm-assistant.service to the
  # device, so the address is (re)applied whenever the tap (re)appears.
  networking.interfaces.${tap}.ipv4.addresses = [
    {
      address = hostAddress;
      prefixLength = 24;
    }
  ];

  # No externalInterface: masquerade on whichever interface the route picks.
  networking.nat = {
    enable = true;
    internalInterfaces = [ tap ];
  };

  # Open the ports in nixos-fw; assistant-in below closes everything else
  # (adam's global allowedTCPPorts would otherwise also apply to the VM).
  networking.firewall.interfaces.${tap}.allowedTCPPorts = hostPorts;

  networking.firewall.extraCommands = teardown + ''
    iptables -w -t mangle -N assistant-drop
    iptables -w -t mangle -A assistant-drop -m limit --limit 10/min -j LOG --log-prefix "assistant-drop: "
    iptables -w -t mangle -A assistant-drop -j DROP

    iptables -w -t mangle -N assistant-in
    iptables -w -t mangle -A assistant-in -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -w -t mangle -A assistant-in -p tcp -m multiport --dports ${
      lib.concatMapStringsSep "," toString hostPorts
    } -j RETURN
    iptables -w -t mangle -A assistant-in -j assistant-drop

    iptables -w -t mangle -N assistant-fwd
    iptables -w -t mangle -A assistant-fwd -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -w -t mangle -A assistant-fwd -p udp --dport 53 -j RETURN
    iptables -w -t mangle -A assistant-fwd -p tcp --dport 53 -j RETURN
    ${lib.concatMapStringsSep "\n" (
      range: "iptables -w -t mangle -A assistant-fwd -d ${range} -j assistant-drop"
    ) privateRanges}
    iptables -w -t mangle -A assistant-fwd -p tcp --dport 443 -m conntrack --ctstate NEW -m limit --limit 10/min -j LOG --log-prefix "assistant-egress: "
    iptables -w -t mangle -A assistant-fwd -p tcp --dport 443 -j RETURN
    iptables -w -t mangle -A assistant-fwd -j assistant-drop

    iptables -w -t mangle -I INPUT 1 -i ${tap} -j assistant-in
    iptables -w -t mangle -I FORWARD 1 -i ${tap} -j assistant-fwd
    ip6tables -w -t mangle -I INPUT 1 -i ${tap} -j DROP
    ip6tables -w -t mangle -I FORWARD 1 -i ${tap} -j DROP
  '';
  networking.firewall.extraStopCommands = teardown;
}
