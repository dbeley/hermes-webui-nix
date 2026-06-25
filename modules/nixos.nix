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
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    users.users.${cfg.user}.linger = true;

    systemd.user.services.hermes-gateway = lib.mkIf cfg.enableGateway {
      unitConfig = {
        Description = "Hermes Gateway (cron jobs, messaging)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "simple";
        Environment = [
          "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:%h/.nix-profile/bin"
          "HERMES_HOME=%h/.hermes"
        ];
        ExecStart = "${cfg.agentPackage}/bin/hermes gateway run";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
