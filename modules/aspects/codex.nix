# Codex as a coding assistant on a workstation, on Tinfoil's models.
# `codex` is OpenAI's CLI as it comes (its own sandbox, approvals and
# terminal UI), with a wrapper that points it at a local, key-holding
# proxy:
#
#   codex  ->  llm-proxy on 127.0.0.1:4011  ->  tinfoil proxy on :3301
#          ->  Tinfoil's enclaves (attested before each connection)
#
# llm-proxy (modules/ark/llm-proxy, Rust) adds the Tinfoil key, relabels
# Codex's `developer` messages `system`, cuts old tool outputs out of long
# sessions and strips Kimi's channel markers from what it says. The key is
# a secret of its own, entered by hand with `ark secrets`, which systemd
# hands to the proxy alone; nobody's shell sees it.
#
#   den.aspects.<host>.includes = [ den.aspects.codex ];
#
# The models: Tinfoil's chat models replace OpenAI's in Codex's catalog, so
# `/model` lists them (and their reasoning levels); `codex -m glm-5-3`
# picks one for a run. kimi-k3 is the default. The wrapper's settings are
# command-line overrides, so ~/.codex/config.toml stays the user's own.
{ ... }:
let
  ports = {
    tinfoil = 3301;
    llm = 4011;
  };

  # Tinfoil's chat models that serve the Responses API
  # (https://docs.tinfoil.sh/models/chat), as Codex's model catalog wants
  # them. Kimi K3 refuses `medium`; the others take the usual three.
  levels = {
    low = "Faster answers, lighter reasoning";
    medium = "Balanced";
    high = "Deeper reasoning for harder problems";
    max = "As deep as the model goes";
  };
  model =
    priority:
    {
      slug,
      name,
      description,
      context,
      vision,
      efforts ? [
        "low"
        "medium"
        "high"
      ],
    }:
    {
      inherit slug description priority;
      display_name = name;
      default_reasoning_level = "high";
      supported_reasoning_levels = map (effort: {
        inherit effort;
        description = levels.${effort};
      }) efforts;
      shell_type = "shell_command";
      visibility = "list";
      supported_in_api = true;
      support_verbosity = false;
      default_reasoning_summary = "auto";
      truncation_policy = {
        mode = "bytes";
        limit = 10000;
      };
      experimental_supported_tools = [ ];
      context_window = context;
      max_context_window = context;
      # Summarize well before the window is full: long sessions re-read
      # everything on every step.
      auto_compact_token_limit = if context * 6 / 10 < 200000 then context * 6 / 10 else 200000;
      input_modalities = [ "text" ] ++ (if vision then [ "image" ] else [ ]);
    };
  catalog.models = builtins.genList (i: model (i + 1) (builtins.elemAt models i)) (
    builtins.length models
  );
  models = [
    {
      slug = "kimi-k3";
      name = "Kimi K3";
      description = "Moonshot's flagship: agentic work and complex tool calling, with vision.";
      context = 262144;
      vision = true;
      efforts = [
        "low"
        "high"
        "max"
      ];
    }
    {
      slug = "glm-5-3";
      name = "GLM 5.3";
      description = "Long-horizon agentic coding, 1M context, text only; a quarter of Kimi's price.";
      context = 1048576;
      vision = false;
    }
    {
      slug = "deepseek-v4-1-flash";
      name = "DeepSeek V4.1 Flash";
      description = "Fast and cheap, 1M context, with vision (experimental).";
      context = 1048576;
      vision = true;
    }
    {
      slug = "gemma4-31b";
      name = "Gemma 4 31B";
      description = "Small and quick, with vision.";
      context = 262144;
      vision = true;
    }
    {
      slug = "gpt-oss-120b";
      name = "gpt-oss 120B";
      description = "OpenAI's open-weight model; the cheapest.";
      context = 131072;
      vision = false;
    }
  ];
in
{
  den.aspects.codex = {
    secrets.codex_tinfoil_api_key.restartUnits = [ "codex-llm.service" ];

    nixos =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      let
        llm = pkgs.callPackage ../ark/_rust.nix { pname = "llm-proxy"; };
        # The newer Codex where the host has nixpkgs-unstable at hand
        # (common/features/pkgs-unstable.nix); its settings below are the
        # current spelling.
        upstream = pkgs.pkgs-unstable.codex or pkgs.codex;
        # Codex wants each catalog model's base instructions; these are its
        # own, the ones it gives a model it does not know, taken from the
        # source of the Codex in use so the two always match.
        catalogFile =
          pkgs.runCommand "codex-tinfoil-models.json"
            {
              nativeBuildInputs = [ pkgs.jq ];
              catalog = builtins.toJSON catalog;
              passAsFile = [ "catalog" ];
            }
            ''
              jq --rawfile prompt ${upstream.src}/codex-rs/models-manager/prompt.md \
                '.models |= map(.model_messages = { instructions_template: $prompt })' \
                "$catalogPath" > $out
            '';
        # TOML values for `codex -c key=value`.
        overrides = [
          ''model_provider="tinfoil"''
          ''model_providers.tinfoil={name="Tinfoil",base_url="http://127.0.0.1:${toString ports.llm}/v1",wire_api="responses",env_key="CODEX_TINFOIL_KEY",requires_openai_auth=false,stream_idle_timeout_ms=300000}''
          ''model_catalog_json="${catalogFile}"''
          ''model="kimi-k3"''
          # OpenAI's hosted web search: not with this provider.
          ''web_search="disabled"''
        ];
        codex = pkgs.writeShellScriptBin "codex" ''
          # The proxy holds the key; Codex only insists the variable exists.
          export CODEX_TINFOIL_KEY=''${CODEX_TINFOIL_KEY:-none}
          exec ${upstream}/bin/codex ${
            lib.concatMapStringsSep " " (o: "-c ${lib.escapeShellArg o}") overrides
          } "$@"
        '';
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
        environment.systemPackages = [ codex ];

        # Tinfoil's attesting proxy (`tinfoil proxy`, from tinfoil-cli). It
        # forwards only the Authorization header a client sends, so on its
        # own the port is of no use.
        systemd.services.codex-tinfoil = {
          description = "Tinfoil attesting proxy, for Codex";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          environment.HOME = "/var/lib/codex-tinfoil";
          serviceConfig = hardening // {
            ExecStart = "${pkgs.tinfoil-cli}/bin/tinfoil proxy -b 127.0.0.1 -p ${toString ports.tinfoil}";
            StateDirectory = "codex-tinfoil";
          };
        };

        systemd.services.codex-llm = {
          description = "Key-holding proxy from Codex to Tinfoil";
          wantedBy = [ "multi-user.target" ];
          after = [ "codex-tinfoil.service" ];
          wants = [ "codex-tinfoil.service" ];
          environment = {
            LLM_PROXY_LISTEN = "127.0.0.1:${toString ports.llm}";
            LLM_PROXY_UPSTREAM = "http://127.0.0.1:${toString ports.tinfoil}";
            # No LLM_PROXY_MODEL: the model Codex asks for goes through.
          };
          serviceConfig = hardening // {
            ExecStart = "${llm}/bin/llm-proxy";
            # Read by systemd as root, handed over as $CREDENTIALS_DIRECTORY/key.
            LoadCredential = "key:${config.sops.secrets.codex_tinfoil_api_key.path}";
          };
        };
      };
  };
}
