# server-setup

## create_odoo_user.sh

Creates (or fixes, if Odoo already created it) the `odoo` user on Ubuntu:

- `/bin/bash` shell + home directory
- full sudo (`sudo` group + `/etc/sudoers.d/90-odoo` NOPASSWD, validated with `visudo -cf`)
- password asked at run time via `passwd` (nothing stored in the script)
- SSH login: installs `openssh-server` if missing, prepares `~/.ssh/authorized_keys`,
  enables password + pubkey auth, fixes `50-cloud-init.conf`, extends `AllowUsers`,
  restarts ssh **only if `sshd -t` passes**
- `ufw allow OpenSSH` if ufw is active

### Run

```bash
sudo bash create_odoo_user.sh
# optionally add a public key:
sudo bash create_odoo_user.sh "ssh-ed25519 AAAA... me@laptop"
```

Quick run (repo is public):

```bash
curl -fsSL https://raw.githubusercontent.com/monegm62/server-setup/main/create_odoo_user.sh | sudo bash
```

With `gh`:

```bash
gh api repos/monegm62/server-setup/contents/create_odoo_user.sh -H "Accept: application/vnd.github.raw" > create_odoo_user.sh && sudo bash create_odoo_user.sh
```

Or with a fine-grained read-only token (`Contents: read` on this repo only):

```bash
curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github.raw" https://api.github.com/repos/monegm62/server-setup/contents/create_odoo_user.sh -o create_odoo_user.sh && sudo bash create_odoo_user.sh
```

## install_odoo19.sh

Installs Odoo 19 Community (official repo) + PostgreSQL + wkhtmltopdf + Nginx reverse proxy
(websocket on 8072, Odoo bound to 127.0.0.1). The database master password is generated and
saved in `/root/odoo-master-password.txt`.

```bash
curl -fsSL https://raw.githubusercontent.com/monegm62/server-setup/main/install_odoo19.sh | sudo bash
# with a domain + free SSL (the domain's DNS must already point to the server):
curl -fsSL https://raw.githubusercontent.com/monegm62/server-setup/main/install_odoo19.sh | sudo bash -s -- erp.example.com
```
