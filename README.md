# hermes-webui-nix

NixOS and Home Manager modules for [Hermes WebUI](https://github.com/nesquena/hermes-webui) — the web interface for [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research.

## Features

- Packages the Hermes WebUI server from upstream releases
- **NixOS module**: opens firewall port, enables user lingering for systemd user services
- **Home Manager module**: creates `hermes-webui` and `hermes-gateway` systemd user services, installs the `hermes` CLI
- Self-contained — brings its own `hermes-agent` via the [llm-agents.nix](https://github.com/numtide/llm-agents.nix) flake input
- Configurable host, port, password file, and gateway toggle
- `nix run` support via the `apps` flake output

## Usage

### 1. Add the flake input

```nix
# flake.nix
inputs = {
  hermes-webui-nix = {
    url = "github:dbeley/hermes-webui-nix";
    inputs.nixpkgs.follows = "nixpkgs";
    # Optional: share the same hermes-agent version across your config
    inputs.llm-agents.follows = "llm-agents";
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

## Secrets with sops-nix

The `passwordFile` option is designed to work with [sops-nix](https://github.com/Mic92/sops-nix). The password file is read at service startup (not at build time), so the secret never enters the Nix store.

### 1. Add the secret to your sops secrets file

```yaml
# secrets/secrets.yaml
hermes-webui-password: ENC[AES256_GCM,data:...,type:str]
```

### 2. Declare the secret in your sops module

```nix
# modules/sops/sops.nix (or wherever you manage sops secrets)
sops.secrets = {
  hermes-webui-password = {
    sopsFile = ../../secrets/secrets.yaml;
    path = "/home/youruser/.config/hermes/webui-password";
  };
};
```

### 3. Reference it in the Home Manager config

```nix
services.hermes-webui = {
  enable = true;
  passwordFile = "$HOME/.config/hermes/webui-password";
};
```

The start script reads the file with `$(cat "$HOME/.config/hermes/webui-password")` and exports it as `HERMES_WEBUI_PASSWORD` before launching the server.

## Running ad-hoc

```sh
# Run the webui directly without installing
nix run github:dbeley/hermes-webui-nix

# Or from a local checkout
nix run .
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

[MIT](LICENSE)
