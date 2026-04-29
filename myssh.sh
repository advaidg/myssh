#!/usr/bin/env bash
# myssh — register SSH servers once, connect by alias forever (shell edition).
#
# Pure-bash implementation. Depends only on OpenSSH (ssh, ssh-keygen,
# ssh-copy-id) and POSIX userland (awk, grep, sed, mktemp). No Python.
#
# SSH config entries are bracketed by `# === BEGIN myssh: <alias> ===`
# markers, identical to the Python edition, so the two are interchangeable.

set -u

VERSION="1.0.0"
EDITION="shell"
KEY_NAME="myssh_id_ed25519"
SSH_DIR="$HOME/.ssh"
KEY_PATH="$SSH_DIR/$KEY_NAME"
PUB_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"
CONFIG_PATH="$SSH_DIR/config"

ALIAS_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
HOST_RE='^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$'
RESERVED_RE='^(register|list|remove|rm|delete|test|help|version)$'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RST=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_RST=""
fi

info()    { printf '%s\n' "$*"; }
step()    { printf '  %s\n' "$*"; }
ok_msg()  { printf '%s%s%s\n' "$C_G" "$*" "$C_RST"; }
warn_msg(){ printf '%s%s%s\n' "$C_Y" "$*" "$C_RST" >&2; }
err_msg() {
  printf '%sError:%s %s\n' "$C_R" "$C_RST" "$1" >&2
  if [ "${2:-}" != "" ]; then printf '  Hint: %s\n' "$2" >&2; fi
}

confirm() {
  local prompt="$1" default_no="${2:-1}" suffix reply
  if [ "$default_no" = "0" ]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  printf '%s %s: ' "$prompt" "$suffix"
  if ! read -r reply; then return 1; fi
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO)   return 1 ;;
    "")          [ "$default_no" = "0" ] && return 0 || return 1 ;;
    *)           return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Filesystem / SSH config plumbing
# ---------------------------------------------------------------------------

ensure_ssh_dir() {
  [ -d "$SSH_DIR" ] || mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR" 2>/dev/null || true
}

read_config_safe() {
  if [ -f "$CONFIG_PATH" ]; then cat "$CONFIG_PATH"; fi
}

write_config_atomic() {
  # Reads new content from stdin and replaces $CONFIG_PATH atomically.
  ensure_ssh_dir
  local tmp
  tmp="$(mktemp "${CONFIG_PATH}.myssh.XXXXXX")"
  cat > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$CONFIG_PATH"
}

# Prints non-zero if alias not found, regardless of who manages it.
alias_exists_anywhere() {
  local alias="$1"
  [ -f "$CONFIG_PATH" ] || return 1
  awk -v a="$alias" '
    BEGIN          { found = 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      if (found) next
      line = $0
      sub(/^[[:space:]]+/, "", line)
      key = tolower(substr(line, 1, 5))
      if (key != "host ") next
      sub(/^[Hh][Oo][Ss][Tt][[:space:]]+/, "", line)
      n = split(line, tokens, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (tokens[i] == a) { found = 1; next }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$CONFIG_PATH"
}

# Prints zero if the alias has a myssh-managed block.
managed_entry_exists() {
  local alias="$1"
  [ -f "$CONFIG_PATH" ] || return 1
  grep -qxF "# === BEGIN myssh: $alias ===" "$CONFIG_PATH"
}

upsert_entry() {
  local alias="$1" host="$2" user="$3" port="$4"
  local body new
  ensure_ssh_dir

  body="$(read_config_safe)"

  # Strip any existing block for this alias.
  body="$(printf '%s' "$body" | awk -v a="$alias" '
    BEGIN { drop = 0 }
    {
      if ($0 == "# === BEGIN myssh: " a " ===") { drop = 1; next }
      if (drop && $0 == "# === END myssh: " a " ===") { drop = 0; next }
      if (!drop) print
    }
  ')"

  # Trim trailing blank lines.
  body="$(printf '%s' "$body" | awk '
    { lines[NR] = $0 }
    END {
      end = NR
      while (end > 0 && lines[end] == "") end--
      for (i = 1; i <= end; i++) print lines[i]
    }
  ')"

  new="$(
    if [ -n "$body" ]; then
      printf '%s\n\n' "$body"
    fi
    printf '# === BEGIN myssh: %s ===\n' "$alias"
    printf 'Host %s\n' "$alias"
    printf '    HostName %s\n' "$host"
    printf '    User %s\n' "$user"
    printf '    Port %s\n' "$port"
    printf '    IdentityFile ~/.ssh/%s\n' "$KEY_NAME"
    printf '    IdentitiesOnly yes\n'
    printf '# === END myssh: %s ===\n' "$alias"
  )"

  printf '%s' "$new" | write_config_atomic
}

delete_entry() {
  local alias="$1"
  [ -f "$CONFIG_PATH" ] || return 1
  managed_entry_exists "$alias" || return 1

  local body
  body="$(awk -v a="$alias" '
    BEGIN { drop = 0 }
    {
      if ($0 == "# === BEGIN myssh: " a " ===") { drop = 1; next }
      if (drop && $0 == "# === END myssh: " a " ===") { drop = 0; next }
      if (!drop) print
    }
  ' "$CONFIG_PATH")"

  # Collapse triple-or-more blank lines into one blank line.
  body="$(printf '%s' "$body" | awk '
    { lines[NR] = $0 }
    END {
      blanks = 0
      for (i = 1; i <= NR; i++) {
        if (lines[i] == "") {
          blanks++
          if (blanks <= 1) print ""
        } else {
          blanks = 0
          print lines[i]
        }
      }
    }
  ')"

  printf '%s' "$body" | write_config_atomic
  return 0
}

# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

validate_alias() {
  local alias="$1"
  if [[ "$alias" =~ $RESERVED_RE ]]; then
    err_msg "alias '$alias' is reserved"
    return 2
  fi
  if [[ ! "$alias" =~ $ALIAS_RE ]]; then
    err_msg "alias must start with a letter or digit and contain only letters, digits, '.', '_', '-' (max 64 chars)"
    return 2
  fi
}

validate_host() {
  local host="$1"
  if [ -z "$host" ] || [ ${#host} -gt 255 ] || [[ ! "$host" =~ $HOST_RE ]]; then
    err_msg "invalid hostname or IP"
    return 2
  fi
}

validate_port() {
  local p="$1"
  if [[ ! "$p" =~ ^[0-9]+$ ]]; then
    err_msg "port must be an integer"
    return 2
  fi
  if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    err_msg "port must be between 1 and 65535"
    return 2
  fi
}

# ---------------------------------------------------------------------------
# Key + remote install
# ---------------------------------------------------------------------------

ensure_managed_key() {
  ensure_ssh_dir
  if [ -f "$KEY_PATH" ] && [ -f "$PUB_KEY_PATH" ]; then
    step "Reusing existing key at ~/.ssh/$KEY_NAME."
    chmod 600 "$KEY_PATH"     2>/dev/null || true
    chmod 644 "$PUB_KEY_PATH" 2>/dev/null || true
    return 0
  fi
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    err_msg "ssh-keygen not found on PATH" "Install OpenSSH client."
    return 1
  fi
  step "Generating new ed25519 key at ~/.ssh/$KEY_NAME..."
  local hn; hn="$(hostname 2>/dev/null || echo localhost)"
  ssh-keygen -t ed25519 -N "" -C "myssh@$hn" -f "$KEY_PATH"
  chmod 600 "$KEY_PATH"     2>/dev/null || true
  chmod 644 "$PUB_KEY_PATH" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_register() {
  local host="$1" alias="$2"
  validate_alias "$alias" || return $?
  validate_host  "$host"  || return $?

  if ! command -v ssh-copy-id >/dev/null 2>&1; then
    err_msg "ssh-copy-id not found on PATH" "It's part of OpenSSH; install via your package manager."
    return 1
  fi

  info "Registering new server: $alias"
  info "Server: $host"

  if alias_exists_anywhere "$alias"; then
    warn_msg "Alias '$alias' already exists in $CONFIG_PATH."
    if ! confirm "Overwrite the existing entry?"; then
      info "Cancelled."
      return 1
    fi
  fi

  local port_input port username
  printf 'Port [22]: '
  if ! read -r port_input; then return 1; fi
  port_input="${port_input:-22}"
  validate_port "$port_input" || return $?
  port="$port_input"

  printf 'Username: '
  if ! read -r username; then return 1; fi
  username="${username#"${username%%[![:space:]]*}"}"
  username="${username%"${username##*[![:space:]]}"}"
  if [ -z "$username" ]; then
    err_msg "Username is required"
    return 2
  fi

  info ""
  step "Checking local SSH key..."
  ensure_managed_key || return 1

  info ""
  step "Copying public key to $username@$host:$port..."
  step "(ssh-copy-id will prompt for the SSH password — it is used once and never stored.)"
  if ! ssh-copy-id -i "$PUB_KEY_PATH" -p "$port" "$username@$host"; then
    err_msg "ssh-copy-id failed" \
      "Common causes: wrong password, host unreachable, or PasswordAuthentication disabled on the server."
    return 1
  fi

  info ""
  step "Updating local SSH config..."
  upsert_entry "$alias" "$host" "$username" "$port"

  info ""
  step "Verifying passwordless login..."
  local verify_err
  verify_err="$(mktemp -t myssh-verify.XXXXXX)"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$alias" true 2>"$verify_err"; then
    err_msg "passwordless login still failing: $(tr '\n' ' ' <"$verify_err")" \
      "Try 'myssh test $alias', or check sshd PubkeyAuthentication on the server."
    rm -f "$verify_err"
    return 1
  fi
  rm -f "$verify_err"

  info ""
  ok_msg "Success."
  info ""
  info "You can now connect using:"
  info "  myssh $alias"
}

cmd_list() {
  if [ ! -f "$CONFIG_PATH" ] || ! grep -q "^# === BEGIN myssh: " "$CONFIG_PATH"; then
    info "No aliases registered yet. Add one with:"
    info "  myssh register <host> <alias>"
    return 0
  fi

  awk '
    BEGIN { in_block = 0 }
    /^# === BEGIN myssh: / {
      a = $0
      sub(/^# === BEGIN myssh: /, "", a)
      sub(/ ===$/, "", a)
      alias = a
      in_block = 1
      hostname = ""; user = ""; port = "22"
      next
    }
    in_block && $1 == "HostName" { hostname = $2; next }
    in_block && $1 == "User"     { user = $2; next }
    in_block && $1 == "Port"     { port = $2; next }
    in_block && /^# === END myssh: / {
      printf "%s\t%s\t%s\t%s\n", alias, user, hostname, port
      in_block = 0
    }
  ' "$CONFIG_PATH" | sort -f | awk -F '\t' '
    { rows[NR] = $0; if (length($1) > w1) w1 = length($1)
      if (length($2) > w2) w2 = length($2)
      if (length($3) > w3) w3 = length($3) }
    END {
      if (w1 < 5) w1 = 5
      if (w2 < 4) w2 = 4
      if (w3 < 4) w3 = 4
      printf "%-*s  %-*s  %-*s  %s\n", w1, "ALIAS", w2, "USER", w3, "HOST", "PORT"
      total = w1 + w2 + w3 + 6 + 4
      sep = ""
      for (i = 0; i < total; i++) sep = sep "-"
      print sep
      for (i = 1; i <= NR; i++) {
        n = split(rows[i], f, "\t")
        printf "%-*s  %-*s  %-*s  %s\n", w1, f[1], w2, f[2], w3, f[3], f[4]
      }
    }
  '
}

cmd_remove() {
  local alias="$1" force="${2:-}"
  validate_alias "$alias" || return $?
  if ! managed_entry_exists "$alias"; then
    err_msg "no managed alias named '$alias'" "Run 'myssh list' to see registered aliases."
    return 1
  fi
  if [ "$force" != "--yes" ] && [ "$force" != "-y" ]; then
    if ! confirm "Remove alias '$alias' from $CONFIG_PATH?"; then
      info "Cancelled."
      return 1
    fi
  fi
  if delete_entry "$alias"; then
    ok_msg "Removed alias '$alias'."
    return 0
  fi
  err_msg "could not remove alias"
  return 1
}

cmd_test() {
  local alias="$1"
  validate_alias "$alias" || return $?
  if ! managed_entry_exists "$alias"; then
    err_msg "alias '$alias' is not managed by myssh" "Run 'myssh list' first."
    return 1
  fi
  info "Testing passwordless login to '$alias'..."
  local out
  out="$(mktemp -t myssh-test.XXXXXX)"
  if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$alias" true 2>"$out"; then
    rm -f "$out"
    ok_msg "Passwordless login works."
    return 0
  fi
  err_msg "passwordless login failed: $(tr '\n' ' ' <"$out")"
  rm -f "$out"
  return 1
}

cmd_connect() {
  local alias="$1"
  validate_alias "$alias" || return $?
  if ! alias_exists_anywhere "$alias"; then
    err_msg "unknown alias '$alias'" "Register it with: myssh register <host> $alias"
    return 1
  fi
  info "Connecting to $alias..."
  exec ssh "$alias"
}

print_help() {
  cat <<EOF
myssh $VERSION ($EDITION) — register SSH servers once, connect by alias forever.

USAGE
  myssh register <host> <alias>   Register a server and set up key-based login.
  myssh <alias>                   SSH into a registered server.
  myssh list                      List registered aliases.
  myssh remove <alias> [--yes]    Remove an alias from local SSH config.
  myssh test <alias>              Verify passwordless login works.
  myssh help                      Show this message.

KEY
  Local key:   ~/.ssh/$KEY_NAME
  SSH config:  ~/.ssh/config (entries bracketed by '# === BEGIN myssh: ... ===')

EXAMPLES
  myssh register 12.34.56.78 prod
  myssh prod
  myssh list
  myssh test prod
  myssh remove prod
EOF
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

main() {
  if [ "$#" -eq 0 ]; then print_help; return 0; fi

  case "$1" in
    -h|--help|help)        print_help; return 0 ;;
    -V|--version|version)  printf 'myssh %s (%s)\n' "$VERSION" "$EDITION"; return 0 ;;
    register)
      shift
      if [ "$#" -ne 2 ]; then
        err_msg "register requires <host> <alias>" "Example: myssh register 12.34.56.78 prod"
        return 2
      fi
      cmd_register "$1" "$2"; return $?
      ;;
    list)
      cmd_list; return $?
      ;;
    remove|rm|delete)
      shift
      if [ "$#" -lt 1 ]; then
        err_msg "remove requires <alias>"; return 2
      fi
      cmd_remove "$@"; return $?
      ;;
    test)
      shift
      if [ "$#" -lt 1 ]; then
        err_msg "test requires <alias>"; return 2
      fi
      cmd_test "$1"; return $?
      ;;
    *)
      if [ "$#" -gt 1 ]; then
        err_msg "unrecognised command '$1'" "Run 'myssh help' for usage."
        return 2
      fi
      cmd_connect "$1"; return $?
      ;;
  esac
}

main "$@"
