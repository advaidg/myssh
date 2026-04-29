#!/usr/bin/env python3
"""myssh — register SSH servers once, connect by alias forever.

Commands:
  myssh register <host> <alias>   set up key-based login and save alias
  myssh <alias>                   connect using the alias
  myssh list                      list registered aliases
  myssh remove <alias>            remove an alias
  myssh test <alias>              verify passwordless login works
  myssh help                      show help
"""
from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import os
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path

VERSION = "1.0.0"

KEY_NAME = "myssh_id_ed25519"
SSH_DIR = Path.home() / ".ssh"
KEY_PATH = SSH_DIR / KEY_NAME
PUB_KEY_PATH = SSH_DIR / f"{KEY_NAME}.pub"
CONFIG_PATH = SSH_DIR / "config"
KNOWN_HOSTS_PATH = SSH_DIR / "known_hosts"

ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$")

RESERVED = {
    "register", "list", "remove", "rm", "delete",
    "test", "help", "--help", "-h", "-V", "--version", "version",
}

BEGIN_MARK = "# === BEGIN myssh: {alias} ==="
END_MARK = "# === END myssh: {alias} ==="
MARK_RE = re.compile(
    r"^# === BEGIN myssh: (?P<alias>[^ ]+) ===\n"
    r"(?P<body>.*?)"
    r"^# === END myssh: (?P=alias) ===\n?",
    re.MULTILINE | re.DOTALL,
)


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def _color() -> bool:
    return sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def info(msg: str) -> None:
    print(msg)


def step(msg: str) -> None:
    print(f"  {msg}")


def ok(msg: str) -> None:
    print((f"\033[32m{msg}\033[0m") if _color() else msg)


def warn(msg: str) -> None:
    line = f"\033[33m{msg}\033[0m" if _color() else msg
    print(line, file=sys.stderr)


def err(msg: str, hint: str | None = None) -> None:
    head = "\033[31mError:\033[0m" if _color() else "Error:"
    print(f"{head} {msg}", file=sys.stderr)
    if hint:
        print(f"  Hint: {hint}", file=sys.stderr)


def confirm(prompt: str, default_no: bool = True) -> bool:
    suffix = " [y/N]: " if default_no else " [Y/n]: "
    try:
        ans = input(prompt + suffix).strip().lower()
    except EOFError:
        return False
    if not ans:
        return not default_no
    return ans in ("y", "yes")


# ---------------------------------------------------------------------------
# Filesystem / config primitives
# ---------------------------------------------------------------------------

def ensure_ssh_dir() -> None:
    SSH_DIR.mkdir(mode=0o700, exist_ok=True)
    try:
        SSH_DIR.chmod(0o700)
    except PermissionError:
        pass


def read_config() -> str:
    if not CONFIG_PATH.exists():
        return ""
    return CONFIG_PATH.read_text()


def write_config(text: str) -> None:
    ensure_ssh_dir()
    tmp = CONFIG_PATH.with_suffix(".myssh.tmp")
    tmp.write_text(text)
    try:
        tmp.chmod(0o600)
    except PermissionError:
        pass
    os.replace(tmp, CONFIG_PATH)
    try:
        CONFIG_PATH.chmod(0o600)
    except PermissionError:
        pass


def render_entry(alias: str, hostname: str, user: str, port: int) -> str:
    body = (
        f"Host {alias}\n"
        f"    HostName {hostname}\n"
        f"    User {user}\n"
        f"    Port {port}\n"
        f"    IdentityFile ~/.ssh/{KEY_NAME}\n"
        f"    IdentitiesOnly yes\n"
    )
    return (
        f"{BEGIN_MARK.format(alias=alias)}\n"
        f"{body}"
        f"{END_MARK.format(alias=alias)}\n"
    )


def parse_managed_entries(text: str) -> list[dict]:
    entries: list[dict] = []
    for m in MARK_RE.finditer(text):
        alias = m.group("alias")
        body = m.group("body")
        fields = {}
        for line in body.splitlines():
            stripped = line.strip()
            if stripped.startswith("HostName "):
                fields["hostname"] = stripped[len("HostName "):].strip()
            elif stripped.startswith("User "):
                fields["user"] = stripped[len("User "):].strip()
            elif stripped.startswith("Port "):
                fields["port"] = stripped[len("Port "):].strip()
        entries.append({
            "alias": alias,
            "hostname": fields.get("hostname", ""),
            "user": fields.get("user", ""),
            "port": fields.get("port", "22"),
        })
    return entries


def find_managed_entry(alias: str) -> dict | None:
    for e in parse_managed_entries(read_config()):
        if e["alias"] == alias:
            return e
    return None


def alias_exists_anywhere(alias: str) -> bool:
    """Return True if any Host stanza in the SSH config references this alias."""
    text = read_config()
    if not text:
        return False
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().startswith("host "):
            tokens = line.split()[1:]
            if alias in tokens:
                return True
    return False


def upsert_entry(alias: str, hostname: str, user: str, port: int) -> None:
    text = read_config()
    new_block = render_entry(alias, hostname, user, port)
    pattern = re.compile(
        rf"^# === BEGIN myssh: {re.escape(alias)} ===\n.*?^# === END myssh: {re.escape(alias)} ===\n?",
        re.MULTILINE | re.DOTALL,
    )
    if pattern.search(text):
        new_text = pattern.sub(new_block, text, count=1)
    else:
        sep = "" if (text == "" or text.endswith("\n\n")) else ("\n" if text.endswith("\n") else "\n\n")
        new_text = text + sep + new_block
    write_config(new_text)


def delete_entry(alias: str) -> bool:
    text = read_config()
    pattern = re.compile(
        rf"^# === BEGIN myssh: {re.escape(alias)} ===\n.*?^# === END myssh: {re.escape(alias)} ===\n?",
        re.MULTILINE | re.DOTALL,
    )
    if not pattern.search(text):
        return False
    new_text = pattern.sub("", text, count=1)
    new_text = re.sub(r"\n{3,}", "\n\n", new_text)
    write_config(new_text)
    return True


# ---------------------------------------------------------------------------
# SSH key management
# ---------------------------------------------------------------------------

def ensure_managed_key() -> None:
    ensure_ssh_dir()
    if KEY_PATH.exists() and PUB_KEY_PATH.exists():
        step(f"Reusing existing key at ~/.ssh/{KEY_NAME}.")
        try:
            KEY_PATH.chmod(0o600)
            PUB_KEY_PATH.chmod(0o644)
        except PermissionError:
            pass
        return
    if shutil.which("ssh-keygen") is None:
        raise RuntimeError("ssh-keygen not found on PATH")
    step(f"Generating new ed25519 key at ~/.ssh/{KEY_NAME}...")
    comment = f"myssh@{socket.gethostname()}"
    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-C", comment, "-f", str(KEY_PATH)],
        check=True,
    )
    try:
        KEY_PATH.chmod(0o600)
        PUB_KEY_PATH.chmod(0o644)
    except PermissionError:
        pass


def read_public_key() -> str:
    return PUB_KEY_PATH.read_text().strip() + "\n"


# ---------------------------------------------------------------------------
# Paramiko-backed remote setup (only path that needs the password)
# ---------------------------------------------------------------------------

def _import_paramiko():
    try:
        import paramiko  # type: ignore
        return paramiko
    except ImportError as e:
        raise RuntimeError(
            "paramiko is required for `register`. Install it with:\n"
            "    python3 -m pip install --user paramiko"
        ) from e


def _fingerprint_sha256(key_bytes: bytes) -> str:
    digest = hashlib.sha256(key_bytes).digest()
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


def _build_host_key_policy(paramiko):
    class ConfirmAddPolicy(paramiko.MissingHostKeyPolicy):
        def missing_host_key(self, client, hostname, key):
            fp = _fingerprint_sha256(key.asbytes())
            warn(f"  Unknown host key for {hostname} ({key.get_name()}): {fp}")
            if not confirm("  Trust this host and add it to known_hosts?"):
                raise paramiko.SSHException("Host key rejected by user")
            ensure_ssh_dir()
            KNOWN_HOSTS_PATH.touch(mode=0o600, exist_ok=True)
            client.get_host_keys().add(hostname, key.get_name(), key)
            with open(KNOWN_HOSTS_PATH, "a") as f:
                f.write(f"{hostname} {key.get_name()} {key.get_base64()}\n")
            try:
                KNOWN_HOSTS_PATH.chmod(0o600)
            except PermissionError:
                pass
    return ConfirmAddPolicy()


def password_login_and_install_key(
    hostname: str, port: int, user: str, password: str, public_key: str
) -> None:
    paramiko = _import_paramiko()
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    if KNOWN_HOSTS_PATH.exists():
        try:
            client.load_host_keys(str(KNOWN_HOSTS_PATH))
        except Exception:
            pass
    client.set_missing_host_key_policy(_build_host_key_policy(paramiko))
    try:
        client.connect(
            hostname=hostname,
            port=port,
            username=user,
            password=password,
            allow_agent=False,
            look_for_keys=False,
            timeout=15,
        )
    except paramiko.AuthenticationException as e:
        raise RuntimeError("password authentication failed") from e
    except (socket.timeout, socket.gaierror) as e:
        raise RuntimeError(f"could not reach {hostname}:{port} — {e}") from e
    except paramiko.SSHException as e:
        raise RuntimeError(f"ssh handshake failed: {e}") from e

    try:
        # Idempotent merge: read pub key from stdin, append if not present, fix perms.
        cmd = (
            "umask 077 && mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
            "touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && "
            "TMP=$(mktemp ~/.ssh/.myssh.XXXXXX) && cat > \"$TMP\" && "
            "while IFS= read -r line; do "
            "  [ -z \"$line\" ] && continue; "
            "  grep -qxF \"$line\" ~/.ssh/authorized_keys || echo \"$line\" >> ~/.ssh/authorized_keys; "
            "done < \"$TMP\" && rm -f \"$TMP\""
        )
        stdin, stdout, stderr = client.exec_command(cmd, timeout=20)
        stdin.write(public_key)
        stdin.channel.shutdown_write()
        rc = stdout.channel.recv_exit_status()
        if rc != 0:
            err_text = stderr.read().decode(errors="replace").strip()
            raise RuntimeError(
                f"remote key install failed (exit {rc}): {err_text or 'no stderr'}"
            )
    finally:
        client.close()


# ---------------------------------------------------------------------------
# Subprocess SSH (passwordless verification + connect)
# ---------------------------------------------------------------------------

def test_alias_passwordless(alias: str, timeout: int = 10) -> tuple[bool, str]:
    if shutil.which("ssh") is None:
        return False, "ssh client not found on PATH"
    try:
        proc = subprocess.run(
            [
                "ssh",
                "-o", "BatchMode=yes",
                "-o", f"ConnectTimeout={timeout}",
                "-o", "StrictHostKeyChecking=accept-new",
                alias,
                "true",
            ],
            capture_output=True,
            text=True,
            timeout=timeout + 5,
        )
        if proc.returncode == 0:
            return True, ""
        return False, (proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}")
    except subprocess.TimeoutExpired:
        return False, "connection timed out"


def exec_ssh(alias: str) -> int:
    if shutil.which("ssh") is None:
        err("ssh client not found.", "Install OpenSSH client and retry.")
        return 127
    if os.name == "posix":
        os.execvp("ssh", ["ssh", alias])
        return 0  # unreachable
    return subprocess.call(["ssh", alias])


# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

def validate_alias(alias: str) -> None:
    if alias.lower() in RESERVED:
        raise ValueError(f"alias '{alias}' is reserved")
    if not ALIAS_RE.match(alias):
        raise ValueError(
            "alias must start with a letter or digit and contain only letters, "
            "digits, '.', '_', '-' (max 64 chars)"
        )


def validate_host(host: str) -> None:
    if not host or len(host) > 255 or not HOST_RE.match(host):
        raise ValueError("invalid hostname or IP")


def validate_port(port_str: str) -> int:
    try:
        port = int(port_str)
    except (TypeError, ValueError):
        raise ValueError("port must be an integer")
    if not (1 <= port <= 65535):
        raise ValueError("port must be between 1 and 65535")
    return port


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_register(args: argparse.Namespace) -> int:
    try:
        validate_alias(args.alias)
        validate_host(args.host)
    except ValueError as e:
        err(str(e), "Use letters, digits, dots, underscores, hyphens.")
        return 2

    info(f"Registering new server: {args.alias}")
    info(f"Server: {args.host}")

    if alias_exists_anywhere(args.alias):
        warn(f"Alias '{args.alias}' already exists in {CONFIG_PATH}.")
        if not confirm("Overwrite the existing entry?"):
            info("Cancelled.")
            return 1

    try:
        port_input = input("Port [22]: ").strip() or "22"
        port = validate_port(port_input)
    except ValueError as e:
        err(str(e))
        return 2
    except EOFError:
        return 1

    try:
        username = input("Username: ").strip()
    except EOFError:
        return 1
    if not username:
        err("Username is required.")
        return 2

    password = getpass.getpass("Password: ")
    if not password:
        err("Password is required for initial setup.")
        return 2

    info("")
    step("Checking local SSH key...")
    try:
        ensure_managed_key()
    except (RuntimeError, subprocess.CalledProcessError) as e:
        err(f"could not prepare SSH key: {e}", "Ensure ssh-keygen is installed.")
        return 1
    public_key = read_public_key()

    info("")
    step("Testing password login and installing public key...")
    try:
        password_login_and_install_key(args.host, port, username, password, public_key)
    except RuntimeError as e:
        msg = str(e)
        hint = None
        if "authentication failed" in msg:
            hint = "Double-check the username and password."
        elif "could not reach" in msg:
            hint = "Verify the host/IP, port, and that your network can reach it."
        elif "host key rejected" in msg.lower():
            hint = "Re-run and accept the fingerprint, or remove the stale entry from ~/.ssh/known_hosts."
        elif "paramiko" in msg:
            hint = None
        err(msg, hint)
        return 1
    finally:
        password = ""  # drop reference

    info("")
    step("Updating local SSH config...")
    try:
        upsert_entry(args.alias, args.host, username, port)
    except OSError as e:
        err(f"could not write {CONFIG_PATH}: {e}")
        return 1

    info("")
    step("Verifying passwordless login...")
    okay, why = test_alias_passwordless(args.alias)
    if not okay:
        err(
            f"passwordless login still failing: {why}",
            "Try `myssh test " + args.alias + "` or check the server's sshd PubkeyAuthentication setting.",
        )
        return 1

    info("")
    ok("Success.")
    info("")
    info("You can now connect using:")
    info(f"  myssh {args.alias}")
    return 0


def cmd_list(_: argparse.Namespace) -> int:
    entries = parse_managed_entries(read_config())
    if not entries:
        info("No aliases registered yet. Add one with:")
        info("  myssh register <host> <alias>")
        return 0
    width = max(len(e["alias"]) for e in entries)
    width = max(width, len("ALIAS"))
    user_w = max(max((len(e["user"]) for e in entries), default=0), len("USER"))
    host_w = max(max((len(e["hostname"]) for e in entries), default=0), len("HOST"))
    header = f"{'ALIAS':<{width}}  {'USER':<{user_w}}  {'HOST':<{host_w}}  PORT"
    info(header)
    info("-" * len(header))
    for e in sorted(entries, key=lambda x: x["alias"].lower()):
        info(f"{e['alias']:<{width}}  {e['user']:<{user_w}}  {e['hostname']:<{host_w}}  {e['port']}")
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    try:
        validate_alias(args.alias)
    except ValueError as e:
        err(str(e))
        return 2
    if not find_managed_entry(args.alias):
        err(f"no managed alias named '{args.alias}'.", "Run `myssh list` to see registered aliases.")
        return 1
    if not args.yes and not confirm(f"Remove alias '{args.alias}' from {CONFIG_PATH}?"):
        info("Cancelled.")
        return 1
    if delete_entry(args.alias):
        ok(f"Removed alias '{args.alias}'.")
        return 0
    err("Could not remove alias (no matching block found).")
    return 1


def cmd_test(args: argparse.Namespace) -> int:
    try:
        validate_alias(args.alias)
    except ValueError as e:
        err(str(e))
        return 2
    entry = find_managed_entry(args.alias)
    if entry is None:
        err(f"alias '{args.alias}' is not managed by myssh.", "Run `myssh list` first.")
        return 1
    info(f"Testing passwordless login to '{args.alias}' ({entry['user']}@{entry['hostname']}:{entry['port']})...")
    okay, why = test_alias_passwordless(args.alias)
    if okay:
        ok("Passwordless login works.")
        return 0
    err(f"passwordless login failed: {why}",
        "Re-run `myssh register " + args.alias + " " + args.alias + "` if the key was rotated.")
    return 1


def cmd_connect(alias: str) -> int:
    try:
        validate_alias(alias)
    except ValueError as e:
        err(str(e))
        return 2
    entry = find_managed_entry(alias)
    if entry is None and not alias_exists_anywhere(alias):
        err(f"unknown alias '{alias}'.", "Register it with `myssh register <host> " + alias + "`.")
        return 1
    info(f"Connecting to {alias}...")
    return exec_ssh(alias)


# ---------------------------------------------------------------------------
# CLI entry
# ---------------------------------------------------------------------------

HELP_TEXT = f"""myssh {VERSION} — register SSH servers once, connect by alias forever.

USAGE
  myssh register <host> <alias>   Register a server and set up key-based login.
  myssh <alias>                   SSH into a registered server.
  myssh list                      List registered aliases.
  myssh remove <alias> [--yes]    Remove an alias from local SSH config.
  myssh test <alias>              Verify passwordless login works.
  myssh help                      Show this message.

KEY
  Local key:   ~/.ssh/{KEY_NAME}
  SSH config:  ~/.ssh/config (entries bracketed by `# === BEGIN myssh: ... ===`)

EXAMPLES
  myssh register 12.34.56.78 prod
  myssh prod
  myssh list
  myssh test prod
  myssh remove prod
"""


def print_help() -> int:
    print(HELP_TEXT)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="myssh", add_help=False, description="myssh CLI")
    p.add_argument("--version", "-V", action="store_true", help="print version and exit")
    p.add_argument("--help", "-h", action="store_true", help="show help")
    sub = p.add_subparsers(dest="command")

    reg = sub.add_parser("register", add_help=False, help="register a server")
    reg.add_argument("host")
    reg.add_argument("alias")

    sub.add_parser("list", add_help=False, help="list aliases")

    rm = sub.add_parser("remove", add_help=False, help="remove an alias")
    rm.add_argument("alias")
    rm.add_argument("--yes", "-y", action="store_true", help="skip confirmation")

    tst = sub.add_parser("test", add_help=False, help="test passwordless login")
    tst.add_argument("alias")

    sub.add_parser("help", add_help=False, help="show help")

    return p


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        return print_help()

    first = argv[0]

    if first in ("-h", "--help", "help"):
        return print_help()
    if first in ("-V", "--version", "version"):
        print(f"myssh {VERSION}")
        return 0

    if first not in {"register", "list", "remove", "rm", "delete", "test"}:
        # Treat unknown first arg as alias for connect.
        if len(argv) > 1:
            err(
                f"unrecognised command '{first}'.",
                "Run `myssh help` for usage."
            )
            return 2
        return cmd_connect(first)

    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:
        return int(e.code or 2)

    cmd = args.command
    if cmd == "register":
        return cmd_register(args)
    if cmd == "list":
        return cmd_list(args)
    if cmd in ("remove", "rm", "delete"):
        return cmd_remove(args)
    if cmd == "test":
        return cmd_test(args)
    if cmd == "help":
        return print_help()
    return print_help()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        sys.exit(130)
