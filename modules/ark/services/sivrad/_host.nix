# Host side of the `sivrad` microVM: a tap link to the guest, NAT, and an
# egress policy. The guest itself is described in ./_guest.nix.
#
# Policy for traffic from the VM (blocked packets are logged with the prefix
# "sivrad-drop: ", allowed HTTPS with "sivrad-egress: "):
#   - to adam itself: only TCP 443 (nginx) and 8123 (Home Assistant);
#   - forwarded: DNS and TCP 443 to public addresses, nothing to the LAN,
#     the tailnet, or link-local ranges; no IPv6 at all.
#   - tailscale: UDP 41641 anywhere, any other UDP to public addresses
#     (STUN, peers). Once the VM is on the tailnet its traffic there is
#     WireGuard, so what it may reach on the tailnet is up to headscale's
#     ACL, not to this chain.
# The rules live in the mangle table because tailscaled inserts its own
# ts-forward chain (which ACCEPTs everything leaving via tailscale0) at the
# top of filter/FORWARD after the NixOS firewall has started.
{ config, lib, ... }:
let
  tap = "vm-sivrad";
  # Directory shared read-only into the guest, so the guest needs no sops of
  # its own. It holds a copy of adam's tailnet pre-auth key
  # (den.aspects.tailnet), root-only, and the saved Signal account
  # signal-account.tar.gz.b64 (sivrad_signal_account, empty until one is
  # saved), world-readable for signal-cli, which runs as `sivrad`. The
  # directory is 0711: no listing.
  # microvm.credentialFiles would be the natural fit, but microvm.nix only
  # implements it for qemu; the cloud-hypervisor runner throws
  # (lib/runners/cloud-hypervisor.nix).
  credentialsDir = "/run/sivrad-credentials";
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
    iptables -w -t mangle -D FORWARD -i ${tap} -j sivrad-fwd 2>/dev/null || true
    iptables -w -t mangle -D INPUT -i ${tap} -j sivrad-in 2>/dev/null || true
    ip6tables -w -t mangle -D FORWARD -i ${tap} -j DROP 2>/dev/null || true
    ip6tables -w -t mangle -D INPUT -i ${tap} -j DROP 2>/dev/null || true
    for chain in sivrad-fwd sivrad-in sivrad-drop; do
      iptables -w -t mangle -F $chain 2>/dev/null || true
      iptables -w -t mangle -X $chain 2>/dev/null || true
    done
  '';
in
{
  microvm.vms.sivrad = {
    # Rebuilding adam must not kill a running conversation; restart the VM
    # by hand (`systemctl restart microvm@sivrad`) to pick up changes.
    restartIfChanged = false;
    # Build the guest from its own nixpkgs instance so the claude-code
    # unfree allowance stays scoped to the VM (see _guest.nix).
    pkgs = null;
    config = {
      imports = [ ./_guest.nix ];
      microvm.shares = [
        {
          tag = "credentials";
          source = credentialsDir;
          mountPoint = "/run/host-credentials";
          proto = "virtiofs";
          readOnly = true;
        }
      ];
    };
  };

  # Refresh the guest's copies before its virtiofsd starts. virtiofsd runs
  # as root and passes ownership through, so in the guest the key is
  # root:root 0400 and invisible to the `sivrad` user. Managed settings keep
  # the model away from all of /run/host-credentials.
  systemd.services.sivrad-credentials = {
    description = "Credentials for the sivrad microVM";
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
    '';
  };
  systemd.services."microvm-virtiofsd@sivrad" = {
    requires = [ "sivrad-credentials.service" ];
    after = [ "sivrad-credentials.service" ];
  };

  # The tap device is created by microvm-tap-interfaces@sivrad.service;
  # scripted networking binds network-addresses-vm-sivrad.service to the
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

  # Open the ports in nixos-fw; sivrad-in below closes everything else
  # (adam's global allowedTCPPorts would otherwise also apply to the VM).
  networking.firewall.interfaces.${tap}.allowedTCPPorts = hostPorts;

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
    iptables -w -t mangle -A sivrad-fwd -p tcp --dport 443 -m conntrack --ctstate NEW -m limit --limit 10/min -j LOG --log-prefix "sivrad-egress: "
    iptables -w -t mangle -A sivrad-fwd -p tcp --dport 443 -j RETURN
    iptables -w -t mangle -A sivrad-fwd -p udp -j RETURN
    iptables -w -t mangle -A sivrad-fwd -j sivrad-drop

    iptables -w -t mangle -I INPUT 1 -i ${tap} -j sivrad-in
    iptables -w -t mangle -I FORWARD 1 -i ${tap} -j sivrad-fwd
    ip6tables -w -t mangle -I INPUT 1 -i ${tap} -j DROP
    ip6tables -w -t mangle -I FORWARD 1 -i ${tap} -j DROP
  '';
  networking.firewall.extraStopCommands = teardown;
}
