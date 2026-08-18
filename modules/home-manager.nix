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

  # Build a Python env that includes the agent's dependencies plus any
  # extra packages (e.g. mnemosyne, sqlite-vec) so that memory-provider
  # plugins can import them at runtime.
  agentPythonEnv = pkgs.python3.withPackages (
    ps:
    (map (p: ps.${p}) cfg.extraPythonPackageNames)
    ++ cfg.extraPythonPackages
  );

  # When extraPythonPackages is non-empty, create a derivation that:
  #   1. Copies the entire agent package (so bin/, share/, lib/ are preserved)
  #   2. Wraps .hermes-wrapped (the real ELF/binary) with HERMES_PYTHON set
  #      to the custom Python env.  This avoids the upstream hermes script
  #      overwriting the value (it does an unconditional `export HERMES_PYTHON=…`).
  #   3. Replaces the `hermes` bin entry with a thin shell script that
  #      execs the wrapped binary, so callers (systemd, CLI) see the same
  #      `hermes` command.
  wrappedAgent =
    if cfg.extraPythonPackages == [] && cfg.extraPythonPackageNames == [] then
      cfg.agentPackage
    else
      pkgs.runCommand "hermes-agent-wrapped"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
          preferLocalBuild = true;
        }
        ''
          mkdir -p $out/bin

          # Copy everything from the original package (lib/, share/, etc.)
          cp -a ${cfg.agentPackage}/* $out/ 2>/dev/null || true

          # Ensure bin/ exists
          mkdir -p $out/bin
          for f in ${cfg.agentPackage}/bin/*; do
            ln -sf "$f" $out/bin/$(basename "$f")
          done

          # Wrap .hermes-wrapped directly — this is the actual binary/script
          # that the hermes wrapper calls.  By setting HERMES_PYTHON here,
          # we guarantee it takes precedence over the upstream script's export.
          wrapProgram $out/bin/.hermes-wrapped \
            --set HERMES_PYTHON "${agentPythonEnv}/bin/python3"

          # Replace the `hermes` entry point with a simple exec wrapper.
          # The upstream hermes script does `export HERMES_PYTHON=…` which
          # would override our value, so we bypass it entirely.
          cat > $out/bin/hermes <<'WRAPPER'
          #! ${pkgs.bash}/bin/bash
          exec -a "hermes" "''${BASH_SOURCE[0]%/*}/.hermes-wrapped" "$@"
          WRAPPER
          chmod +x $out/bin/hermes
        '';
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

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "$HOME/.config/hermes/env";
      description = ''
        Path to a file with <literal>KEY=VALUE</literal> lines loaded as
        environment for both the WebUI and Gateway user services (systemd
        <literal>EnvironmentFile=</literal>). Use a sops-managed runtime path,
        not a Nix store path, to keep secrets out of the store. Takes
        precedence over <option>extraEnv</option> for any duplicated variable.
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
    home.packages = [
      wrappedAgent
      pkgs.agent-browser
      pkgs.docker
      pkgs.nodejs
      pkgs.ripgrep
    ];

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
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        WorkingDirectory = "%h/.hermes";
        ExecStart = "${wrappedAgent}/bin/hermes gateway run";
        ExecReload = "/bin/kill -USR1 $MAINPID";
        ExecStopPost = "-${wrappedAgent}/bin/python -m gateway.cgroup_cleanup";
        Restart = "always";
        RestartForceExitStatus = [
          75
        ];
        RestartSec = 5;
        TimeoutStopSec = 210;
        KillMode = "mixed";
        KillSignal = "SIGTERM";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

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
          "HERMES_WEBUI_AGENT_DIR=${wrappedAgent}/${pkgs.python3.sitePackages}"
          "PYTHONPATH=${wrappedAgent}/${pkgs.python3.sitePackages}"
          "HERMES_BUNDLED_PLUGINS=${wrappedAgent}/share/hermes/plugins"
          "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:%h/.nix-profile/bin"
        ];
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        ExecStart =
          let
            startScript = pkgs.writeShellScript "hermes-webui-start" ''
              ${lib.optionalString (cfg.passwordFile != null) ''
                if [ -f "${cfg.passwordFile}" ]; then
                  export HERMES_WEBUI_PASSWORD=$(cat "${cfg.passwordFile}")
                fi
              ''}
              HERMES_PYTHON=$(grep -oP "HERMES_PYTHON='\K[^']+" ${wrappedAgent}/bin/hermes 2>/dev/null || true)
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
