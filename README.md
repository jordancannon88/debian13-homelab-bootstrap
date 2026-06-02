# debian13-homelab-bootstrap

Opinionated bootstrap scripts for a fresh **Debian 13 (Trixie)** homelab host.

`init.sh` is the entry point. It checks for root, installs `curl`, then for each
script asks whether to run it — using a **local copy if present** in the current
directory, or offering to **download it from GitHub** if it isn't.

| Script | What it does |
| --- | --- |
| `init.sh` | Orchestrator: root check, installs `curl`, then runs the scripts below (local copy or download), one at a time. |
| `harden.sh` | System hardening — admin users + SSH keys, SSH lockdown, nftables firewall (deny-by-default), fail2ban, unattended-upgrades, persistent journald, sysctl hardening, AppArmor, AIDE, Lynis audit. |
| `docker.sh` | Docker Engine + Compose + **rootless** Docker, plus a `/opt/docker` layout with an example app. |
| `ancillary.sh` | Extra packages (`btop`) + the **fish** shell, set as the default shell for users `harden.sh` created (or current users you pick). |

All scripts are **idempotent**, support a **dry-run** preview, prompt before
making changes, back up every file they edit, and print a full recap at the end.

> ⚠️ **Run on a fresh host / VM.** `harden.sh` changes SSH and the firewall.
> Keep your current session open and test a new SSH login before disconnecting.

---

## Option 1 — Run `init.sh` (recommended · easiest · quickest)

Downloads the other scripts for you; nothing to clone. Run as **root**.

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh | sudo bash
```

Or download, review, then run (recommended over piping to a shell):

```bash
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh -o init.sh
less init.sh        # review it first
sudo bash init.sh
```

`init.sh` will, for each script in turn:

1. ask **whether to run it** (`Run harden.sh?` / `Run docker.sh?`);
2. use the file from the current directory if it exists, otherwise show the full
   raw URL and ask to **download** it;
3. run it and wait for it to finish before moving to the next.

---

## Option 2 — `git clone` and run locally (skips downloading)

Clone the repo and run everything from local files. Because the scripts sit next
to `init.sh`, it uses the **local copies** and never touches the network for them.

```bash
git clone https://github.com/jordancannon88/debian13-homelab-bootstrap.git
cd debian13-homelab-bootstrap
sudo ./init.sh
```

Prefer to run the steps yourself, in order:

```bash
sudo ./harden.sh     # 1) harden the system
sudo ./docker.sh     # 2) install Docker + Compose (rootless)
sudo ./ancillary.sh  # 3) extra packages (btop) + fish shell
```

---

## Dry run first (recommended)

`harden.sh`, `docker.sh`, and `ancillary.sh` ask **Dry run vs Actual** on start,
and default to a dry run that previews every action without changing anything.
To force it:

```bash
sudo DRY_RUN=1 ./harden.sh
sudo DRY_RUN=1 ./docker.sh
sudo DRY_RUN=1 ./ancillary.sh
```

---

## Useful environment overrides

`init.sh`
- `REPO_RAW_BASE=<url>` — base raw URL to download scripts from (e.g. a fork/branch)
- `ASSUME_YES=1` — answer "yes" to every prompt (automation)

`harden.sh`
- `ADMIN_USERS="admin jordan"` — admin users to create/harden (sudo + SSH key)
- `PUBKEY="ssh-ed25519 ..."` / `PUBKEY_<user>="..."` — SSH public key(s)
- `SSH_PORT=22` · `ALLOW_SSH_CIDRS="1.2.3.4/32"` · `ALLOW_HTTP=1` · `ALLOW_HTTPS=1`
- `ENABLE_SSH_2FA=1` · `SKIP_UPGRADE=1` · `DOCKER_COMPAT=1` · `DISABLE_ROOT_LOGIN=1`

`docker.sh`
- `DOCKER_USER=<name>` — user to set up rootless Docker for
- `SETUP_ROOTLESS=1` · `DISABLE_ROOTFUL=1` · `USERNS_METHOD=apparmor|sysctl|none`
- `CREATE_OPT_DOCKER=1` · `EXAMPLE_APP=<name>` · `EXAMPLE_PORT=8080`

`ancillary.sh`
- `FISH_USERS="u1 u2"` — set fish as the default shell for exactly these users (skips prompts)

Common to all: `DRY_RUN=1|0`, `ASSUME_YES=1`.

---

## Requirements

- Debian 13 (Trixie); also works on Debian 12/11 for most steps.
- Root (`sudo`).
- Outbound HTTPS for Option 1 and for Docker installation.
