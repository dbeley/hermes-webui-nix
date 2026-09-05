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

  # Explicit executable wins; otherwise nixpkgs chromium. null → no local browser.
  browserExecutable =
    if cfg.browser.local.executable != null then
      cfg.browser.local.executable
    else if cfg.browser.local.enable then
      "${pkgs.chromium}/bin/chromium"
    else
      null;

  # Declared env that must be authoritative even if a stale systemd drop-in
  # leaks Environment= values (see removeStaleDropins).
  browserEnvEntry = lib.optional (browserExecutable != null)
    "AGENT_BROWSER_EXECUTABLE_PATH=${browserExecutable}";
  browserEnvExport = lib.optionalString (browserExecutable != null) ''
    export AGENT_BROWSER_EXECUTABLE_PATH="${browserExecutable}"
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

    removeStaleDropins = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to purge unmanaged drop-ins for the two systemd user units this
        module owns (hermes-webui and hermes-gateway) on every activation.

        Systemd applies any file found in a unit's
        <filename>~/.config/systemd/user/<replaceable>unit</replaceable>.service.d/</filename>
        directory on top of the unit, and neither Home Manager nor NixOS manage
        that directory.  A stale, hand-written drop-in therefore survives every
        switch and silently overrides the declared
        <literal>Environment=PYTHONPATH=</literal> with hardcoded Nix store
        paths. When the agent package is bumped, that can inject an old
        hermes-agent's <filename>site-packages</filename> into a newer
        hermes-webui process and crash it with e.g.
        <literal>cannot import name 'mkdir_under_hermes_home'</literal>.

        Since this module declares the complete service, unmanaged drop-ins are
        treated as stale state and removed. Disable only if you deliberately
        add your own drop-ins for these two units.
      '';
    };

    browser.local = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable local Chromium browser tools (``tool browser`` / ``browser-cdp``).
          This adds a Chromium build to the user environment and points the agent
          at it via <envar>AGENT_BROWSER_EXECUTABLE_PATH</envar> on both the
          WebUI and Gateway services, so the local browser tools are advertised
          and usable.

          Hermes discovers a browser via <envar>AGENT_BROWSER_EXECUTABLE_PATH</envar>,
          then the <literal>chromium</literal>/<literal>google-chrome</literal>
          binaries on <envar>PATH</envar>, then the Playwright browser cache.
          Without a browser binary, the local browser tools are hidden
          (<literal>tools/browser_tool.py:_chromium_installed</literal>). Headless
          mode works, so this is fine on servers/VMs too.

          The cloud <literal>browser-use</literal> provider is unrelated: it needs
          a <envar>BROWSER_USE_API_KEY</envar> (or the Nous tool gateway) and no
          local browser.
        '';
      };

      executable = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = lib.literalExpression ''
          "''${pkgs.google-chrome}/bin/google-chrome"
        '';
        description = ''
          Path to the Chromium/Chrome executable to use. Defaults to
          <literal>pkgs.chromium</literal> when <option>enable</option> is set.
          Set this to point at an existing browser instead of adding chromium
          as a dependency (e.g. an unfree Google Chrome).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages =
      [ cfg.agentPackage pkgs.agent-browser pkgs.docker pkgs.nodejs pkgs.ripgrep ]
      ++ lib.optional (browserExecutable != null && cfg.browser.local.executable == null)
        pkgs.chromium;

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
        ] ++ browserEnvEntry;
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        WorkingDirectory = "%h/.hermes";
        # Run through a start script so the declared environment always wins:
        # systemd drops any <unit>.service.d/ drop-in on top of the unit, but
        # an export here is applied last and cannot be overridden. The agent
        # resolves its own modules via HERMES_PYTHON_SRC_ROOT (set by the
        # wrapper), so a stale PYTHONPATH is never needed — unset it to avoid
        # shadowing modules with old store paths.
        ExecStart =
          let
            startScript = pkgs.writeShellScript "hermes-gateway-start" ''
              unset PYTHONPATH 2>/dev/null || true
              ${browserEnvExport}
              exec "${cfg.agentPackage}/bin/hermes" gateway run
            '';
          in
          "${startScript}";
        ExecReload = "/bin/kill -USR1 $MAINPID";
        ExecStopPost = "-${cfg.agentPackage}/bin/python -m gateway.cgroup_cleanup";
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
          "HERMES_WEBUI_AGENT_DIR=${cfg.agentPackage}/${pkgs.python3.sitePackages}"
          "PYTHONPATH=${cfg.agentPackage}/${pkgs.python3.sitePackages}"
          "HERMES_BUNDLED_PLUGINS=${cfg.agentPackage}/share/hermes/plugins"
          "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:%h/.nix-profile/bin"
        ] ++ browserEnvEntry;
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        ExecStart =
          let
            startScript = pkgs.writeShellScript "hermes-webui-start" ''
              # The declared environment is authoritative: re-export it here so
              # a stale <unit>.service.d/ drop-in can never override it (drop-in
              # Environment= wins over the unit's own, but an export in the
              # start script wins over both). See removeStaleDropins.
              export HERMES_WEBUI_HOST="${cfg.host}"
              export HERMES_WEBUI_PORT=${toString cfg.port}
              export HERMES_WEBUI_AGENT_DIR="${cfg.agentPackage}/${pkgs.python3.sitePackages}"
              export PYTHONPATH="${cfg.agentPackage}/${pkgs.python3.sitePackages}"
              export HERMES_BUNDLED_PLUGINS="${cfg.agentPackage}/share/hermes/plugins"
              ${browserEnvExport}

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

    # Stale drop-in purge. This removes any leftover hand-written drop-in
    # (e.g. from a pre-module era that injected PYTHONPATH) that would silently
    # override the declared environment above and mix store paths of different
    # hermes-agent versions. Runs after Home Manager has synced/reloaded units.
    home.activation.hermesWebuiPurgeStaleDropins = lib.mkIf cfg.removeStaleDropins (
      lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
        _purged=0
        for _u in hermes-webui hermes-gateway; do
          _d="$HOME/.config/systemd/user/$_u.service.d"
          if [ -d "$_d" ] && [ -n "$(ls -A "$_d" 2>/dev/null || true)" ]; then
            rm -f "$_d"/*
            rmdir "$_d" 2>/dev/null || true
            _purged=1
          fi
        done
        if [ "$_purged" = 1 ]; then
          systemctl --user daemon-reload 2>/dev/null || true
          systemctl --user try-restart hermes-webui hermes-gateway 2>/dev/null || true
        fi
      ''
    );
  };
}
