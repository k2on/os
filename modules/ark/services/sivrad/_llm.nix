# The model behind sivrad, as the guest sees it: llm-proxy on loopback
# (modules/ark/llm-proxy, Rust, as the sivrad-llm service), an
# OpenAI-compatible proxy that the agent (./_codex.nix)
# sends everything to with no key and the model name `sivrad`. It forwards
# upstream with the real key and the real model name, so where the model
# runs is the two environment variables below and the agent's
# configuration never knows. Today that is Tinfoil (tinfoil.sh): open
# models served from confidential-computing enclaves, reached through
# Tinfoil's own proxy, which checks the enclave's attestation against their
# transparency log before each connection and then forwards requests over
# the verified channel. Tomorrow it may be a model on adam's GPU.
#   imports = [ (import ./_llm.nix { inherit ports; }) ];
#
# The key comes from adam (./_host.nix, from the secrets repo) as
# /run/host-credentials/tinfoil_api_key, root-only, which systemd hands to
# sivrad-llm as a credential; nothing else in the container can read it.
{ ports }:
{ pkgs, lib, ... }:
let
  llm = pkgs.callPackage ../../_rust.nix { pname = "llm-proxy"; };
  hardening = {
    DynamicUser = true;
    Restart = "always";
    RestartSec = "10s";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
    ];
    UMask = "0077";
  };
in
{
  # Tinfoil's attesting proxy (`tinfoil proxy`, from tinfoil-cli). It
  # forwards only the Authorization header a client sends, so the key stays
  # with sivrad-llm; by itself the port is of no use to anyone.
  systemd.services.sivrad-tinfoil = {
    description = "Tinfoil attesting proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment.HOME = "/var/lib/sivrad-tinfoil";
    serviceConfig = hardening // {
      ExecStart = "${pkgs.tinfoil-cli}/bin/tinfoil proxy -b 127.0.0.1 -p ${toString ports.tinfoil}";
      StateDirectory = "sivrad-tinfoil";
    };
  };

  systemd.services.sivrad-llm = {
    description = "The model behind sivrad: key-holding proxy to the upstream";
    wantedBy = [ "multi-user.target" ];
    after = [ "sivrad-tinfoil.service" ];
    wants = [ "sivrad-tinfoil.service" ];
    unitConfig.RequiresMountsFor = "/run/host-credentials";
    environment = {
      LLM_PROXY_LISTEN = "127.0.0.1:${toString ports.llm}";
      # Where the model is. To move it, change these two lines: say, a
      # model on adam's GPU with Ollama there (open the port to the
      # container in ./_host.nix first):
      #   LLM_PROXY_UPSTREAM = "http://192.168.77.1:11434";
      #   LLM_PROXY_MODEL = "qwen3:32b";
      # and drop the credential and sivrad-tinfoil.
      LLM_PROXY_UPSTREAM = "http://127.0.0.1:${toString ports.tinfoil}";
      # Tinfoil's chat models (https://docs.tinfoil.sh/models/chat): glm-5-3
      # is their pick for agentic, long-horizon tool use, with a 1M context,
      # at under half Kimi K3's price for input and a quarter for output.
      # It is text-only, so an image in a thread (a photo sent over Signal
      # and looked at, a screenshot) would fail that turn and every one
      # after it. kimi-k3 has vision: the proxy asks it to describe each
      # image and glm reads the description instead, kept by the image's
      # hash in the state directory so a thread pays for each image once.
      # (Its channel markers, `<|open|> response`, are stripped by the
      # proxy and the channel.) Both serve the Responses API.
      LLM_PROXY_MODEL = "glm-5-3";
      LLM_PROXY_VISION_MODEL = "kimi-k3";
    };
    serviceConfig = hardening // {
      ExecStart = "${llm}/bin/llm-proxy";
      # The image descriptions, as $STATE_DIRECTORY.
      StateDirectory = "sivrad-llm";
      # Read by systemd as root, handed over as $CREDENTIALS_DIRECTORY/key.
      LoadCredential = "key:/run/host-credentials/tinfoil_api_key";
    };
  };

  # Only the agent may ask the model (the owner match, xt_owner, which
  # ./_host.nix loads on adam): every process in the container may
  # otherwise connect to loopback ports, and the proxy asks no password.
  networking.firewall.extraCommands = ''
    ip46tables -D OUTPUT -o lo -j sivrad-llm 2>/dev/null || true
    ip46tables -F sivrad-llm 2>/dev/null || true
    ip46tables -X sivrad-llm 2>/dev/null || true
    ip46tables -N sivrad-llm
    ip46tables -A sivrad-llm -p tcp --dport ${toString ports.llm} -m owner --uid-owner sivrad -j RETURN
    ip46tables -A sivrad-llm -p tcp --dport ${toString ports.llm} -j DROP
    ip46tables -I OUTPUT 1 -o lo -j sivrad-llm
  '';
  networking.firewall.extraStopCommands = ''
    ip46tables -D OUTPUT -o lo -j sivrad-llm 2>/dev/null || true
    ip46tables -F sivrad-llm 2>/dev/null || true
    ip46tables -X sivrad-llm 2>/dev/null || true
  '';
}
