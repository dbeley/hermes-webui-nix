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

2. **NixOS module** (`modules/nixos.nix`): Opens firewall port, enables user lingering. Also defines a `hermes-gateway` systemd **user** service (redundant with Home Manager's definition — see Bug 2).

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

The package applies a `sed` patch to `api/streaming.py` fixing an approval routing bug. If version bumps break the patch, it fails **silently** — the import line and function body are checked in CI only at build time (the build succeeds, but the patch may have no effect). Verify manually after updates.

## Known Bugs

### Bug 1 — PYTHONPATH / AGENT_DIR point to source, not installed package

**Files:** `modules/home-manager.nix:119-120`

```nix
# WRONG — agentPackage.src is raw fetchFromGitHub source, not installed Python site-packages
"HERMES_WEBUI_AGENT_DIR=${cfg.agentPackage.src}"
"PYTHONPATH=${cfg.agentPackage.src}"
```

`cfg.agentPackage.src` resolves to the raw fetched source tree (`/nix/store/xxx-hermes-agent-source/`). The WebUI needs the installed Python site-packages (`/nix/store/xxx-hermes-agent/lib/python3.13/site-packages/`). Using `src` means agent dependencies aren't available and the WebUI may fail at runtime.

**Fix:** Point to the installed site-packages path:

```nix
"HERMES_WEBUI_AGENT_DIR=${cfg.agentPackage}/${pkgs.python3.sitePackages}"
"PYTHONPATH=${cfg.agentPackage}/${pkgs.python3.sitePackages}"
```

The `hermes-agent` package itself confirms this path via its `HERMES_PYTHON_SRC_ROOT` wrapper arg.

---

### Bug 2 — Duplicate gateway systemd user service

**Files:** `modules/nixos.nix:59-76` and `modules/home-manager.nix:78-105`

Both modules define `systemd.user.services.hermes-gateway`. The NixOS module should only handle system-level concerns (firewall, lingering). The Home Manager module correctly handles the user service. When both are used together, the service is defined twice, which can cause merge conflicts or unexpected behavior depending on evaluation order.

**Fix:** Remove the gateway service definition from `modules/nixos.nix` — keep only the Home Manager definition.

---

### Bug 3 — Patch silently breaks on version bump

**File:** `pkgs/hermes-webui.nix:27-42`

The `patchPhase` uses `sed` targeting specific lines and patterns (`/import.*_approval_sse_notify_locked/`, `/def _approval_notify_cb/`). If upstream changes import order, adds/removes lines, or renames functions, `sed` applies no changes and the build succeeds with an unfixed approval bug.

**Fix:** Either (a) validate the patch with a grep check in `installPhase`, or (b) maintain proper patch files in-tree and use the `patches` attribute with a `patchPhase` assertion.

---

### Bug 4 — HEAD~1 assumption in auto-update workflow

**File:** `.github/workflows/auto-update.yml:37`

```bash
if [ -z "$(git diff --name-only HEAD~1 HEAD)" ]; then
```

Assumes `HEAD` is a commit created by `nix-update --commit`. If `nix-update` finds no update (no commit made) or the repo state is shallow, `HEAD~1` may not exist. The `git diff` command would error rather than gracefully detecting no changes.

**Fix:** Check `git rev-parse HEAD~1` first, or use `git status --porcelain` to detect changes before/after.

---

## Notes for Maintainers

- The `flake.lock` pins `llm-agents.nix` — version bumps of `hermes-webui` don't affect the agent version.
- `passwordFile` is read at runtime (shell `cat` in the start script), keeping secrets out of the Nix store.
- The start script's `HERMES_PYTHON` extraction (`grep -oP "HERMES_PYTHON='\K[^']+"`) depends on the `hermes` wrapper's internal format — fragile if the upstream agent changes its wrapper.
- Supporting `x86_64-linux` and `aarch64-linux` only.
