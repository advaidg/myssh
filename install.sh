#!/usr/bin/env bash
# myssh installer for macOS / Linux / WSL / Git-Bash on Windows.
#
# Installs myssh to ~/.local/bin/myssh and ensures that directory is on PATH.

set -euo pipefail

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_CYAN=$'\033[36m'

if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

info()    { printf '%s\n' "$*"; }
step()    { printf '  %s\n' "$*"; }
success() { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()    { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
error()   { printf '%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/myssh.py"
BIN_DIR="${MYSSH_BIN_DIR:-$HOME/.local/bin}"
TARGET="$BIN_DIR/myssh"
VENV_DIR="${MYSSH_VENV_DIR:-$HOME/.local/share/myssh/venv}"

if [ ! -f "$SOURCE" ]; then
  error "myssh.py not found next to install.sh ($SOURCE)."
  exit 1
fi

# ---- detect OS ------------------------------------------------------------
OS_KIND="unknown"
case "$(uname -s 2>/dev/null || echo)" in
  Darwin*)               OS_KIND="macos" ;;
  Linux*)                OS_KIND="linux" ;;
  MINGW*|MSYS*|CYGWIN*)  OS_KIND="windows-bash" ;;
esac
info "${C_BOLD}myssh installer${C_RESET}"
step "Detected: $OS_KIND"

# ---- locate python --------------------------------------------------------
PYTHON_BIN=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      PYTHON_BIN="$(command -v "$cand")"
      break
    fi
  fi
done
if [ -z "$PYTHON_BIN" ]; then
  error "Python 3.8+ is required but was not found."
  step  "Install Python 3 from https://python.org or via your package manager."
  exit 1
fi
step "Python:  $PYTHON_BIN ($($PYTHON_BIN --version 2>&1))"

# ---- check ssh tooling ----------------------------------------------------
missing=()
for tool in ssh ssh-keygen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  error "Required tools missing: ${missing[*]}"
  case "$OS_KIND" in
    macos) step "Install via: xcode-select --install" ;;
    linux) step "Install via: sudo apt install openssh-client  (or your distro equivalent)" ;;
    windows-bash) step "Install OpenSSH from Windows Settings > Apps > Optional Features." ;;
  esac
  exit 1
fi
step "ssh:     $(command -v ssh)"
step "keygen:  $(command -v ssh-keygen)"

# ---- bundled venv for paramiko -------------------------------------------
# Use a dedicated virtualenv so paramiko works even on PEP 668-managed Pythons
# (Homebrew, Debian-packaged python3, etc.) and never leaks into system site.
info ""
step "Preparing virtualenv at $VENV_DIR..."
mkdir -p "$(dirname "$VENV_DIR")"
if [ ! -x "$VENV_DIR/bin/python3" ] && [ ! -x "$VENV_DIR/bin/python" ]; then
  if ! "$PYTHON_BIN" -m venv "$VENV_DIR"; then
    error "Could not create virtualenv at $VENV_DIR."
    step "On Debian/Ubuntu: sudo apt install python3-venv"
    exit 1
  fi
fi

VENV_PY="$VENV_DIR/bin/python3"
[ -x "$VENV_PY" ] || VENV_PY="$VENV_DIR/bin/python"

if ! "$VENV_PY" -c 'import paramiko' >/dev/null 2>&1; then
  step "Installing paramiko into venv (required for 'myssh register')..."
  "$VENV_PY" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
  if ! "$VENV_PY" -m pip install --quiet paramiko; then
    warn "paramiko install failed. Retrying with verbose output:"
    "$VENV_PY" -m pip install paramiko || {
      error "Could not install paramiko into $VENV_DIR."
      step  "Fix the error above, then re-run ./install.sh"
      exit 1
    }
  fi
fi

# From here on, the installed myssh shebang must point at the venv python.
PYTHON_BIN="$VENV_PY"
step "Using interpreter: $PYTHON_BIN"

# ---- install binary -------------------------------------------------------
mkdir -p "$BIN_DIR"
info ""
info "Install location: ${C_CYAN}$TARGET${C_RESET}"

if [ -e "$TARGET" ]; then
  if ! cmp -s "$SOURCE" "$TARGET"; then
    if [ -t 0 ] && [ "${MYSSH_FORCE:-0}" != "1" ]; then
      printf 'A different myssh is already installed at %s. Overwrite? [y/N]: ' "$TARGET"
      read -r reply || reply=""
      case "$reply" in
        y|Y|yes|YES) ;;
        *) info "Cancelled."; exit 1 ;;
      esac
    fi
  fi
fi

cp "$SOURCE" "$TARGET"
chmod 0755 "$TARGET"

# Ensure shebang resolves to the python we validated. Rewrite first line to be safe.
TMP="$TARGET.tmp"
{
  printf '#!%s\n' "$PYTHON_BIN"
  tail -n +2 "$TARGET"
} > "$TMP"
mv "$TMP" "$TARGET"
chmod 0755 "$TARGET"

# ---- PATH plumbing --------------------------------------------------------
needs_path=true
case ":$PATH:" in
  *":$BIN_DIR:"*) needs_path=false ;;
esac

added_to=""
if $needs_path; then
  shell_name="$(basename "${SHELL:-bash}")"
  candidates=()
  case "$shell_name" in
    zsh)  candidates=("$HOME/.zshrc" "$HOME/.profile") ;;
    bash)
      [ "$OS_KIND" = "macos" ] \
        && candidates=("$HOME/.bash_profile" "$HOME/.profile" "$HOME/.bashrc") \
        || candidates=("$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile")
      ;;
    *)    candidates=("$HOME/.profile") ;;
  esac

  profile=""
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then profile="$c"; break; fi
  done
  [ -z "$profile" ] && profile="${candidates[0]}"

  marker="# Added by myssh installer"
  line="export PATH=\"$BIN_DIR:\$PATH\""

  if [ -f "$profile" ] && grep -Fq "$marker" "$profile" 2>/dev/null; then
    step "PATH already touched in $profile (skipping)."
  else
    if [ -f "$profile" ]; then
      cp "$profile" "$profile.myssh.bak.$(date +%Y%m%d%H%M%S)"
    fi
    {
      [ -s "$profile" ] && printf '\n'
      printf '%s\n%s\n' "$marker" "$line"
    } >> "$profile"
    added_to="$profile"
  fi
fi

# ---- verify ---------------------------------------------------------------
info ""
step "Running myssh help..."
if ! PATH="$BIN_DIR:$PATH" "$TARGET" help >/dev/null; then
  error "myssh failed to run. Inspect $TARGET."
  exit 1
fi

info ""
success "myssh installed successfully."
info ""
if [ -n "$added_to" ]; then
  info "Added $BIN_DIR to PATH via $added_to."
  info "Restart your terminal or run:"
  info "  source $added_to"
elif $needs_path; then
  info "Add $BIN_DIR to your PATH manually if 'myssh' is not found."
fi
info ""
info "Usage:"
info "  myssh register <server-address> <alias>"
info "  myssh <alias>"
