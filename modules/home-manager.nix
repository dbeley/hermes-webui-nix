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

  hermes-webui = pkgs.callPackage ../pkgs/hermes-webui.nix { };

  # Site-packages path for the hermes agent (where gateway.cgroup_cleanup lives)
  hermesSitePackages = "${cfg.agentPackage}/${pkgs.python3.sitePackages}";

  # Wrapper for ExecStopPost — runs gateway.cgroup_cleanup with the correct
  # PYTHONPATH so Python can find the module on NixOS (where site-packages
  # are not on the default search path).
  cgroupCleanup = pkgs.writeShellScript "hermes-cgroup-cleanup" ''
    export PYTHONPATH="${hermesSitePackages}:$PYTHONPATH"
    exec ${pkgs.python3}/bin/python3 -m gateway.cgroup_cleanup "$@"
  '';

  # Helper to check if syncUnit is enabled (we need it for the activation script)
  syncUnitEnabled = cfg.enableGateway && cfg.syncUnit;
in
{
  options.services.hermes-webui = {
    enable = lib.mkEnableOption "Hermes WebUI";

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Host address to bind the WebUI server to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "TCP port for the WebUI server to listen on.";
    };

    enableGateway = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable the Hermes Gateway user service.
        The gateway handles cron jobs and messaging platform integrations
        (Telegram, Discord, Slack, etc.). Requires the NixOS module's
        services.hermes-webui.enableGateway to also be set.
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "$HOME/.config/hermes/webui-password";
      description = ''
        Path to a file containing the WebUI password.
        If set, the contents will be read at service start and exported as
        <envar>HERMES_WEBUI_PASSWORD</envar>.
        Use a runtime path (e.g. a sops-managed secret), not a Nix store path,
        to avoid leaking the password into the world-readable store.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = hermes-webui;
      defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/hermes-webui.nix { }";
      description = "The hermes-webui package to use.";
    };

    agentPackage = lib.mkOption {
      type = lib.types.package;
      default = hermesAgent;
      defaultText = lib.literalExpression "llm-agents.packages.\\${pkgs.system}.hermes-agent";
      description = "The hermes-agent package to use.";
    };

    syncUnit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to synchronise the gateway systemd unit with the exact template
        that `hermes gateway status` expects, by regenerating it after every
        home-manager activation.

        Hermes generates its systemd unit using runtime values (python path,
        current PATH, resolved HERMES_HOME) that cannot be reproduced statically
        in a Nix module. When enabled, an activation hook runs `hermes gateway
        install --force --no-start-now` after the Nix-managed unit has been
        written, overwriting it with the exact expected content.

        This eliminates the "⚠ Installed gateway service definition is outdated"
        warning from `hermes gateway status` on NixOS, at the cost of the unit
        being a flat file (not a Nix store symlink) until the next rebuild.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.agentPackage ];

    # Gateway service — defined here (Home Manager) so systemd user service
    # enable symlinks (default.target.wants/) are created correctly at activation.
    # The NixOS module provides the complementary enableGateway option and
    # handles system-level setup (firewall, user lingering).
    systemd.user.services.hermes-gateway = lib.mkIf cfg.enableGateway {
      Unit = {
        Description = "Hermes Agent Gateway - Messaging Platform Integration";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        StartLimitIntervalSec = 0;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Type = "simple";
        Environment = [
          "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:%h/.nix-profile/bin"
          "HERMES_HOME=%h/.hermes"
        ];
        WorkingDirectory = "%h/.hermes";
        ExecStart = "${cfg.agentPackage}/bin/hermes gateway run";
        ExecReload = "/bin/kill -USR1 $MAINPID";
        ExecStopPost = "-${cgroupCleanup}";
        Restart = "always";
        RestartSec = 5;
        RestartForceExitStatus = [ "75" ];
        TimeoutStopSec = 210;
        KillMode = "mixed";
        KillSignal = "SIGTERM";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Activation hook — sync the gateway unit file with the exact template
    # that `hermes gateway status` compares against, to eliminate the
    # "outdated service definition" warning.
    #
    # On NixOS the unit file is a symlink into the read-only Nix store, so
    # we must remove it first before letting hermes install its generated
    # flat file.
    home.activation.syncHermesGatewayUnit = lib.mkIf syncUnitEnabled (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        _unit="$HOME/.config/systemd/user/hermes-gateway.service"
        if [ -L "$_unit" ]; then
          rm -f "$_unit"
        fi
        if ! ${cfg.agentPackage}/bin/hermes gateway install --force --no-start-now 2>&1; then
          echo "hermes-webui: warning: failed to sync gateway unit (non-fatal)" >&2
        fi
      ''
    );

    systemd.user.services.hermes-webui = {
      Unit = {
        Description = "Hermes WebUI";
        After = [ "network.target" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Environment = [
          "HERMES_WEBUI_HOST=${cfg.host}"
          "HERMES_WEBUI_PORT=${toString cfg.port}"
          "HERMES_WEBUI_AGENT_DIR=${cfg.agentPackage}/${pkgs.python3.sitePackages}"
          "PYTHONPATH=${cfg.agentPackage}/${pkgs.python3.sitePackages}"
          "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:%h/.nix-profile/bin"
        ];
        ExecStart =
          let
            startScript = pkgs.writeShellScript "hermes-webui-start" ''
              ${lib.optionalString (cfg.passwordFile != null) ''
                if [ -f "${cfg.passwordFile}" ]; then
                  export HERMES_WEBUI_PASSWORD=$(cat "${cfg.passwordFile}")
                fi
              ''}
              HERMES_PYTHON=$(grep -oP "HERMES_PYTHON='\K[^']+" ${cfg.agentPackage}/bin/hermes 2>/dev/null || true)
              if [ -n "$HERMES_PYTHON" ] && [ -x "$HERMES_PYTHON" ]; then
                cd ${cfg.package}/share/hermes-webui
                exec "$HERMES_PYTHON" server.py
              else
                exec ${cfg.package}/bin/hermes-webui
              fi
            '';
          in
          "${startScript}";
        Restart = "always";
        RestartSec = 10;
      };
    };
  };
}
