{
  config,
  lib,
  ...
}:
let
  cfg = config.services.hermes-webui;
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
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    users.users.${cfg.user}.linger = true;
  };
}
