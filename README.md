# myssh

Register an SSH server **once** with username + password, and `myssh` will:

- generate a local ed25519 key pair (or reuse the existing one),
- copy the public key to the server,
- fix the remote `~/.ssh` permissions,
- write a clean entry into your local `~/.ssh/config`,
- verify passwordless login works,

…so that every connection from then on is a single command.

```bash
myssh register 12.34.56.78 prod   # one-time setup
myssh prod                         # every other day
```

The password is only used in memory during the initial handshake; it is never written to disk and never sent to the server again.

---

## Install

### macOS / Linux / WSL / Git Bash

```bash
./install.sh
```

What it does:

1. Detects your OS and shell.
2. Validates that `python3` (≥3.8), `ssh`, and `ssh-keygen` are present.
3. Creates a dedicated virtualenv at `~/.local/share/myssh/venv` and installs `paramiko` into it (only needed for `register`). This sidesteps PEP 668 / externally-managed Python issues.
4. Copies `myssh.py` → `~/.local/bin/myssh` (`0755`) and rewrites the shebang to point at the venv's Python so the tool is self-contained.
5. Adds `~/.local/bin` to your PATH via the right shell profile (backup file written first).
6. Runs `myssh help` to confirm the install.

Override defaults: `MYSSH_BIN_DIR=/somewhere/else`, `MYSSH_VENV_DIR=/somewhere/else`. Skip the overwrite prompt with `MYSSH_FORCE=1`.

### Windows (PowerShell)

```powershell
.\install.ps1            # per-user install (default)
.\install.ps1 -System    # all users (falls back to per-user if no admin)
.\install.ps1 -Force     # don't prompt before overwriting
```

What it does:

1. Validates Python 3.8+ and the OpenSSH client (`ssh`, `ssh-keygen`).
2. Creates a dedicated virtualenv at `%USERPROFILE%\.local\share\myssh\venv` and installs `paramiko` into it.
3. Copies `myssh.py` to `%USERPROFILE%\.local\bin\` and writes a `myssh.cmd` shim that calls the venv's Python.
4. Adds the install directory to PATH (User scope by default).
5. Runs `myssh help`.

If OpenSSH is missing, the installer points you to:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

After install, restart your terminal so `PATH` updates take effect.

---

## Commands

### Register a server

```bash
myssh register <server-address> <alias>
```

Example:

```text
$ myssh register 12.34.56.78 prod
Registering new server: prod
Server: 12.34.56.78
Port [22]:
Username: ubuntu
Password: ********

  Checking local SSH key...
  Generating new ed25519 key at ~/.ssh/myssh_id_ed25519...

  Testing password login and installing public key...
  Updating local SSH config...
  Verifying passwordless login...

Success.

You can now connect using:
  myssh prod
```

If the alias already exists in your `~/.ssh/config` (managed by `myssh` or hand-rolled), you'll be asked to confirm before it's overwritten.

The first time you connect to a new host, the unknown host key fingerprint is shown and you must accept it before the key install proceeds.

### Connect

```bash
myssh prod
```

Looks up the alias and runs `ssh prod`. On POSIX it `exec`s into ssh, so you get the normal terminal experience.

### List

```bash
myssh list
```

```text
ALIAS  USER    HOST          PORT
-----  ------  ------------  ----
prod   ubuntu  12.34.56.78   22
stage  ec2     10.0.7.4      2222
```

Only `myssh`-managed entries are listed (others in `~/.ssh/config` are left untouched).

### Test

```bash
myssh test prod
```

Runs `ssh -o BatchMode=yes prod true`. Tells you exactly why if the key isn't accepted.

### Remove

```bash
myssh remove prod          # asks before deleting
myssh remove prod --yes    # skip confirmation
```

Only deletes the bracketed `myssh` block from `~/.ssh/config`. The remote `authorized_keys` file is left alone — that's a remote-side concern.

### Help / version

```bash
myssh help
myssh --version
```

---

## What goes where

| Path | Purpose |
|---|---|
| `~/.ssh/myssh_id_ed25519` | Private key (`0600`). Never leaves your machine. |
| `~/.ssh/myssh_id_ed25519.pub` | Public key (copied to remote). |
| `~/.ssh/config` | Aliases. `myssh` blocks are wrapped in `# === BEGIN myssh: <alias> ===` markers so they're easy to spot and easy to remove. |
| `~/.ssh/known_hosts` | First-time host fingerprints, written only after you confirm. |
| `~/.local/bin/myssh` | The CLI entry point (shebang points at the venv below). |
| `~/.local/share/myssh/venv` | Dedicated virtualenv that owns `paramiko`. Delete this directory to fully uninstall. |

Example managed entry:

```sshconfig
# === BEGIN myssh: prod ===
Host prod
    HostName 12.34.56.78
    User ubuntu
    Port 22
    IdentityFile ~/.ssh/myssh_id_ed25519
    IdentitiesOnly yes
# === END myssh: prod ===
```

---

## Security notes

- The password is read with `getpass`, used once for the initial connect, and dropped immediately. It is not logged, not saved, and not transmitted after the public key is installed.
- The private key is generated locally with `ssh-keygen -t ed25519` and never sent to the server.
- The remote install command is run via SSH `exec_command` and reads the public key from **stdin**, so the key contents never get interpolated into a shell string. It also fixes `~/.ssh` to `0700` and `authorized_keys` to `0600`, and is idempotent (re-running won't duplicate keys).
- Unknown host keys require explicit confirmation before being added to `~/.ssh/known_hosts`.
- Aliases are validated against `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` and reserved subcommand names are blocked.

---

## Troubleshooting

| Problem | What to try |
|---|---|
| `paramiko is required for register` | Re-run `./install.sh` (or `.\install.ps1` on Windows) — it creates the venv and installs paramiko there. |
| `password authentication failed` | Re-check the user/password. Some servers disable `PasswordAuthentication`; you'll need to install the public key by hand the first time. |
| `could not reach <host>:<port>` | Check the IP/hostname, the port, and that nothing (firewall, security group) is blocking outbound SSH. |
| `passwordless login still failing` after register | Run `myssh test <alias>` to see the exact ssh error. Common cause: server has `PubkeyAuthentication no` or `~/.ssh` perms drifted. |
| `Host key verification failed` | The remote host key changed. If expected, edit `~/.ssh/known_hosts` and remove the stale line; otherwise investigate before continuing. |
| `myssh: command not found` after install | Restart your terminal, or `source` the shell profile that the installer touched (it tells you which one). |

---

## Files in this repo

```
myssh.py        Main CLI utility (single file)
install.sh      Mac/Linux installer
install.ps1     Windows installer
README.md       This document
```
