
# Purpose: Install single-user Nix, configure nix.conf features, ensure git,
# clone .yuko repo (supports private SSH clone), run home-manager, and start tmux.
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# YukoLoader.sh
# Purpose: Install single-user Nix, configure nix.conf features, ensure git,
# clone .yuko repo (supports private SSH clone), run home-manager, and start tmux.
# Idempotent and conservative: asks before destructive changes.

### Configuration
REPO_SSH="git@github.com:trynn-tech/.yuko.git"
REPO_HTTPS="https://github.com/trynn-tech/.yuko.git"
FLAKE_REF=".#yuko-core"
NIX_INSTALL_URL="https://nixos.org/nix/install"
NIX_CONF_DIR="$HOME/.config/nix"
NIX_CONF_FILE="$NIX_CONF_DIR/nix.conf"
NIX_CONF_LINE="experimental-features = nix-command flakes"
TMUX_SESSION_NAME="yuko"

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

confirm() {
    # If non-interactive, treat as yes (CI friendliness)
    if [ "${CI:-}" = "true" ] || [ ! -t 0 ]; then
        return 0
    fi
    read -r -p "$1 [y/N]: " ans
    case "$ans" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

### 1) Ensure curl is installed (or install it)
if ! command -v curl >/dev/null 2>&1; then
    warn "curl is not installed."
    if command -v apt >/dev/null 2>&1; then
        log "Attempting to install curl with apt (requires sudo)..."
        sudo apt update && sudo apt install -y curl
    elif command -v dnf >/dev/null 2>&1; then
        log "Attempting to install curl with dnf (requires sudo)..."
        sudo dnf install -y curl
    elif command -v pacman >/dev/null 2>&1; then
        log "Attempting to install curl with pacman (requires sudo)..."
        sudo pacman -Sy --noconfirm curl
    else
        err "Package manager not detected. Please install curl manually and re-run this script."
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        err "Failed to install curl. Aborting."
        exit 1
    fi
fi

### 2) Install single-user Nix if not present
if ! command -v nix >/dev/null 2>&1; then
    log "Nix not detected — installing single-user Nix."

    # Use the official installer but don't auto-exec a login shell here
    if confirm "Proceed to download and run the Nix installer from $NIX_INSTALL_URL?"; then
        sh <(curl --proto '=https' --tlsv1.2 -sSfL "$NIX_INSTALL_URL") --no-daemon
        log "Nix installer finished. You may need to restart the shell or source profile files."
    else
        err "User aborted Nix installation."
        exit 1
    fi
else
    log "Nix detected; skipping Nix installer."
fi

# Source nix profile if present (attempt; harmless if not)
if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

### 3) Ensure Nix config directory and enable flakes + nix-command
mkdir -p "$NIX_CONF_DIR"
if [ -f "$NIX_CONF_FILE" ]; then
    if grep -Fxq "$NIX_CONF_LINE" "$NIX_CONF_FILE"; then
        log "Nix config already contains experimental features."
    else
        log "Appending experimental features to $NIX_CONF_FILE"
        printf '%s\n' "$NIX_CONF_LINE" >> "$NIX_CONF_FILE"
    fi
else
    log "Creating $NIX_CONF_FILE with experimental features."
    printf '%s\n' "$NIX_CONF_LINE" > "$NIX_CONF_FILE"
fi

# (Re-source if possible)
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    log "Wrote Nix configuration to $NIX_CONF_FILE (XDG_CONFIG_HOME=$XDG_CONFIG_HOME)"
else
    log "Wrote Nix configuration to $NIX_CONF_FILE"
fi

### 4) Ensure git is available (via system or nix)
ensure_git() {
    if command -v git >/dev/null 2>&1; then
        log "git already present."
        return 0
    fi

    log "git is not installed. Falling back to ephemeral git via nix-shell..."

    # Use nix shell (pure ephemeral environment) to supply git
    if GITBIN=$(nix shell nixpkgs#git -c which git 2>/dev/null); then
        export PATH="$(dirname "$GITBIN"):$PATH"
        log "Ephemeral git activated at: $GITBIN"
        return 0
    else
        log "FATAL: git is not installed and failed to launch in nix shell."
        return 1
    fi
}

ensure_git || exit 1

### 5) Optional: Setup ssh-agent and load keys (helpful for private repo clone)
start_ssh_agent_and_add_keys() {
    # If an agent is already active, use it; otherwise start a new one.
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
        log "SSH_AUTH_SOCK already set; public keys may already be loaded."
    else
        log "Starting ssh-agent..."
        eval "$(ssh-agent -s)" >/dev/null
    fi

    # Try to add common default keys if they exist
    added_any=0
    for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_ed25519_sk"; do
        if [ -f "$key" ]; then
            ssh-add "$key" >/dev/null 2>&1 || warn "ssh-add failed for $key (maybe passphrase required)."
            added_any=1
        fi
    done

    if [ "$added_any" -eq 0 ]; then
        warn "No default SSH keys found in ~/.ssh. If the repository is private, ensure you have keys available or use HTTPS."
    else
        log "SSH keys attempted to be loaded into agent. If passphrases are required, you may be prompted."
    fi
}

start_ssh_agent_and_add_keys

### 6) Clone the repo (prefer SSH for private repos, fallback to HTTPS)
CLONE_DIR="$HOME/.yuko"
if [ -d "$CLONE_DIR/.git" ]; then
    log "Repository already cloned at $CLONE_DIR. Pulling latest changes..."
    git -C "$CLONE_DIR" pull --rebase || warn "git pull failed — you may need to resolve conflicts manually."
else
    log "Attempting to clone $REPO_SSH into $CLONE_DIR (SSH preferred)."
    if git ls-remote "$REPO_SSH" >/dev/null 2>&1; then
        git clone "$REPO_SSH" "$CLONE_DIR"
    else
        warn "SSH clone failed or not accessible. Falling back to HTTPS clone."
        git clone "$REPO_HTTPS" "$CLONE_DIR"
    fi
fi

## 7) TODO: Integrate bash snippet with bash script
## 7) Write ~/.yuko/.yuko-env.nix

write_user_env() {
    local env_dir="$HOME/.yuko"
    local env_file="$env_dir/.yuko-env.nix"

    mkdir -p "$env_dir"

    local default_user="$(whoami)"
    local default_home="$HOME"

    echo "=== Yuko Environment User Setup ==="
    read -r -p "Username [$default_user]: " username
    username=${username:-$default_user}

    read -r -p "Home directory [$default_home]: " homedir
    homedir=${homedir:-$default_home}

    cat > "$env_file" <<EOF
{
  userName = "${username}";
  homeDir  = "${homedir}";
}
EOF

    echo "Written: $env_file"
}

write_user_env

### 8) Run home-manager using the flake in the checked-out repo
if [ -d "$CLONE_DIR" ]; then
    log "Running home-manager switch with flake $FLAKE_REF in $CLONE_DIR."

    # Prefer nix run home-manager/master if available
    if command -v nix >/dev/null 2>&1; then
        # Use the repository path as flake input
        pushd "$CLONE_DIR" >/dev/null
        if nix --version >/dev/null 2>&1; then
            # Two strategies: use nix run (modern) or nix-shell fallback
            if nix run home-manager/master -- --version >/dev/null 2>&1; then
                log "Using nix run home-manager to switch."
                nix run home-manager/master -- switch --flake "$FLAKE_REF"
            else
                log "Falling back to nix-shell invocation for home-manager."
                nix-shell -p home-manager --run "home-manager switch --flake $FLAKE_REF"
            fi
        else
            warn "Nix not usable in current shell; skipping home-manager invocation."
        fi
        popd >/dev/null
    else
        warn "nix command not found; cannot run home-manager."
    fi
else
    err "Clone directory $CLONE_DIR not found — aborting home-manager step."
fi

### 9) Offer to start tmux (install via nix if missing)
if command -v tmux >/dev/null 2>&1; then
    log "tmux available."
else
    log "tmux not found; installing via nix profile."
    nix profile install nixpkgs#tmux || warn "Could not install tmux automatically."
fi

if command -v tmux >/dev/null 2>&1; then
    if confirm "Start (or attach to) tmux session '$TMUX_SESSION_NAME' now?"; then
        log "Attaching to tmux session..."
        exec tmux new -A -s "$TMUX_SESSION_NAME"
    else
        log "Skipping tmux start as requested."
    fi
else
    warn "tmux still not available; finishing script."
fi

log "YukoLoader finished successfully."
exit 0

