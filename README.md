# hermes-webui-nix

NixOS and Home Manager modules for [Hermes WebUI](https://github.com/nesquena/hermes-webui) — the web interface for [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research.

## Features

- Packages the Hermes WebUI server from upstream releases
- **NixOS module**: opens firewall port, enables user lingering for systemd user services
- **Home Manager module**: creates `hermes-webui` and `hermes-gateway` systemd user services, installs the `hermes` CLI
- Self-contained — brings its own `hermes-agent` via the [llm-agents.nix](https://github.com/numtide/llm-agents.nix) flake input
- Configurable host, port, password file, and gateway toggle

## Usage

### 1. Add the flake input

```nix
# flake.nix
inputs = {
  hermes-webui-nix = {
    url = "github:dbeley/hermes-webui-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

### 2. Import the modules

The project provides two modules that work together:

- **NixOS module** (`nixosModules.default`) — system-level config: firewall, user lingering
- **Home Manager module** (`homeModules.default`) — user services, package installation

```nix
# In your NixOS configuration (system modules):
modules = [
  inputs.hermes-webui-nix.nixosModules.default
];

# In your Home Manager configuration (home modules):
modules = [
  inputs.hermes-webui-nix.homeModules.default
];
```

### 3. Enable and configure

```nix
# NixOS system config
services.hermes-webui = {
  enable = true;
  user = "youruser";
  port = 8787;
};

# Home Manager config
services.hermes-webui = {
  enable = true;
  host = "0.0.0.0";
  port = 8787;
  enableGateway = true;
  passwordFile = "$HOME/.config/hermes/webui-password";
};
```

## Options

### NixOS module (`services.hermes-webui`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable system-level config |
| `port` | port | `8787` | Firewall port to open |
| `user` | string | *(required)* | User to enable lingering for |

### Home Manager module (`services.hermes-webui`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable Hermes WebUI |
| `host` | string | `0.0.0.0` | Bind address |
| `port` | port | `8787` | Listen port |
| `enableGateway` | bool | `true` | Enable the Hermes Gateway service |
| `passwordFile` | nullOr str | `null` | Path to password file (runtime path, not Nix store) |
| `package` | package | *(from this flake)* | The hermes-webui package |
| `agentPackage` | package | *(from llm-agents)* | The hermes-agent package |

## How it works

The WebUI server (`server.py`) needs to import Hermes Agent Python modules at runtime. Rather than duplicating the agent's Python environment, the service extracts the `HERMES_PYTHON` path from the `hermes` wrapper script and uses that interpreter to run `server.py`. This gives the WebUI access to all agent dependencies without a second Python environment.

The Gateway service runs `hermes gateway run`, which handles scheduled cron jobs and messaging platform integrations (Telegram, Discord, Slack, etc.).

## License

MIT
