{ llm-agents }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-webui;
  llm = llm-agents.packages.${pkgs.system};
  hermesAgent = llm.hermes-agent;
in
{
  options.services.hermes-webui = {
    enable = lib.mkEnableOption "Hermes WebUI system configuration (firewall, user lingering)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = ''
        TCP port to open in the firewall for the Hermes WebUI server.
        Must match the port configured in the Home Manager module.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Username to enable lingering for.
        Lingering is required so that systemd user services (the WebUI and
        Gateway) start at boot and keep running after the user logs out.
      '';
    };

    enableGateway = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable the Hermes Gateway user service.
        The gateway handles cron jobs and messaging platform integrations
        (Telegram, Discord, Slack, etc.).
      '';
    };

    agentPackage = lib.mkOption {
      type = lib.types.package;
      default = hermesAgent;
      defaultText = lib.literalExpression "llm-agents.packages.\\${pkgs.system}.hermes-agent";
      description = ''
        The hermes-agent package to use for the gateway service.
      '';
    };

    extraPythonPackages = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [];
      example = lib.literalExpression "with pkgs.python3Packages; [ mnemosyne sqlite-vec ]";
      description = ''
        Additional Python packages to include in the agent's Python
        environment.  Use this for memory-provider plugins (e.g. Mnemosyne)
        or other optional dependencies that need to be importable at runtime.
        Each element should be a Python package derivation.
      '';
    };

    extraPythonPackageNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = lib.literalExpression "[ \"mnemosyne\" \"sqlite-vec\" ]";
      description = ''
        Additional Python package names (attribute names under
        <literal>pkgs.python3Packages</literal>) to include in the agent's
        Python environment.  Convenience option for simple cases where you
        just need to name packages by their nixpkgs attribute.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    users.users.${cfg.user}.linger = true;
  };
}
