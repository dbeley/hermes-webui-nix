# AGENTS.md — Developer Guide for AI Agents

## Repository Overview

`hermes-webui-nix` is a **Nix flake** that packages [Hermes WebUI](https://github.com/nesquena/hermes-webui) for NixOS and Home Manager. It bundles the upstream Python web server, wires in the `hermes-agent` runtime via [llm-agents.nix](https://github.com/numtide/llm-agents.nix), and provides systemd user services for the WebUI and Gateway.

```
├── flake.nix                 # Entry point: packages, modules, overlays, apps
├── pkgs/hermes-webui.nix     # Package derivation: fetch, patch, wrap
├── modules/nixos.nix         # NixOS module: firewall, lingering
├── modules/home-manager.nix  # Home Manager module: user services, config
├── .github/workflows/        # CI: weekly auto-update with PR
```

No build system beyond `nix build` / `nix flake check`. No tests.

## Tech Stack

- **Language:** Nix (all source files)
- **Framework:** Nix flake + NixOS/Home Manager module system
- **Upstream:** Python web server (not in this repo)
- **CI:** GitHub Actions (weekly `nix-update` + auto PR)

## Key Architecture

1. **Package** (`pkgs/hermes-webui.nix`): Fetches upstream GitHub release, applies a `sed` patch to `api/streaming.py` (approval routing fix), wraps `server.py` with Python deps (`pyyaml`, `cryptography`).

2. **NixOS module** (`modules/nixos.nix`): Opens firewall port, enables user lingering.

3. **Home Manager module** (`modules/home-manager.nix`): Defines `hermes-webui` and `hermes-gateway` systemd user services. The start script extracts `HERMES_PYTHON` from the agent's wrapper to reuse its Python environment.

4. **Runtime model:** WebUI extracts `HERMES_PYTHON` from the `hermes` CLI wrapper, then runs `server.py` with that interpreter — sharing the agent's Python environment instead of duplicating it.

## Module Options

### NixOS module (`services.hermes-webui`)
| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `enable` | bool | false | |
| `port` | port | 8787 | Firewall |
| `user` | str | required | Linger target |
| `enableGateway` | bool | true | |
| `agentPackage` | package | from llm-agents | |

### Home Manager module (`services.hermes-webui`)
| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `enable` | bool | false | |
| `host` | str | "0.0.0.0" | Bind address |
| `port` | port | 8787 | |
| `enableGateway` | bool | true | |
| `passwordFile` | nullOr str | null | Runtime path, not store |
| `package` | package | this flake | |
| `agentPackage` | package | from llm-agents | |

## Flake Outputs

- `packages.${system}.hermes-webui` — the package
- `apps.${system}.hermes-webui` — `nix run`
- `nixosModules.default` / `nixosModules.hermes-webui`
- `homeModules.default` / `homeModoles.hermes-webui`
- `overlays.default`

## Common Operations

```bash
# Build
nix build .#hermes-webui

# Run directly
nix run .

# Check syntax
nix flake check

# Update flake inputs
nix flake update

# Bump version manually
nix shell nixpkgs#nix-update -c nix-update --build hermes-webui
```

## Patch Note

The package applies a `sed` patch to `api/streaming.py` fixing an approval routing bug. If version bumps break the patch, it fails **silently** — the `installPhase` now validates the patch was applied, so a broken patch causes a build failure.

## Notes for Maintainers

- The `flake.lock` pins `llm-agents.nix` — version bumps of `hermes-webui` don't affect the agent version.
- `passwordFile` is read at runtime (shell `cat` in the start script), keeping secrets out of the Nix store.
- The start script's `HERMES_PYTHON` extraction (`grep -oP "HERMES_PYTHON='\K[^']+"`) depends on the `hermes` wrapper's internal format — fragile if the upstream agent changes its wrapper.
- Supporting `x86_64-linux` and `aarch64-linux` only.
