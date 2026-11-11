# mbp-hub RUNBOOK

The whole procedure for turning a 2017 13" MacBook Pro (MacBookPro14,1) into
a headless Ubuntu Server 26.04.1 LTS "hub", and proving that it works before
you trust it.

Everything in this runbook is done by a human. Nothing here touches the old
data. Whether that data is already on TeraBox and the USB stick is checklist
item 1 and 2 of section 3 - confirm both before you erase anything.

---

## 1. Design

| Decision | Choice | Why |
|---|---|---|
| Base OS | Ubuntu Server 26.04.1 LTS (`resolute`), no desktop | LTS, headless, the only LTS with the 26.04 coreutils/uutils/sudo-rs behaviour this kit was tested against |
| Install media | `ubuntu-26.04.1-live-server-amd64.iso` from releases.ubuntu.com | Official image, SHA256 verified by the mac-prep script |
| Target disk | The whole internal SSD (Apple SSD AP0512J, 500 GB) | The old macOS installation is not needed once the rescue is confirmed (section 3) |
| Partitioning | GPT, 1 GB EFI + the rest ext4, no LVM | Simple, no LVM/encryption on the root, easy to resize, predictable for a headless box |
| Encryption | None on the root; secrets live in a LUKS2 container file (`/var/lib/vault/vault.img`) | Full-disk encryption on a machine with a broken panel and a service-required battery is a lockout risk; a container file can be backed up and unlocked selectively |
| Remote access | Tailscale (WireGuard) + OpenSSH (publickey only) + mosh | Works from a phone on any network, no port forwarding, no exposed SSH on the public internet |
| Media server | Jellyfin, native from Jellyfin's apt repo | No Docker in the core; native means fewer moving parts and easier hardware transcoding |
| Docker | Optional module only | Not needed for the core; published ports bypass ufw |
| Agents | `claude` and `opencode`, installed for the unprivileged `agent` user, usable only while the vault is open | The agent has no password and no sudo, and it cannot read any secret until a human unlocks the vault |
| Power-loss handling | Read/write of the Intel LPC `0xa4` bit via `setpci`, to be verified by a plug-pull test | The MacBook has no separate power button worth relying on; after an AC cut it must come back by itself |
| Battery | Keep it in the machine, or replace it | A service-required battery with the machine running on AC is a slow machine; with the battery REMOVED the firmware asserts PROCHOT and the CPU is throttled hard |
| Wi-Fi | Apple's BCM4350 board files (`brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.*`) | TODO(verify): the generic firmware is widely reported to be slower, but this was **not** measured on this machine - see known unknown 4 |

---

## 2. Hardware

* The CPU is an **Intel Core i5-7360U (2 cores / 4 threads)** with **Intel Iris
  Plus Graphics 640** (PCI device ID 0x5926). Both were measured on this
  machine; "Kaby Lake" is inferred from the model number. Intel's
  specification lists Quick Sync Video for this part, so Jellyfin hardware
  transcoding is expected to work - but that has not been checked on Linux
  yet (see the known-unknowns table).
* The machine has **2 USB-C ports**. The charger takes **one** of them.
* A hub with **HDMI + Ethernet + power pass-through** is therefore the right
  accessory: one USB-C in, video out, a real Ethernet jack, and the charger
  still charges through the same cable.
* A **cheap USB-C keyboard** is optional. It is only needed for the installer's
  disk-partitioning screen; everything else can be done over SSH from a phone.
* You also want: a USB stick (8 GB or more) for the installer, and an Ethernet
  cable if you are using the hub's Ethernet jack.

---

## 3. Pre-wipe checklist

Do not start the install until every line is true.

1. **The rescue is verified.** The TeraBox copy is complete and verified
   (see `FINAL-SYNC-AND-WIPE-READINESS.md` in `/mbp-rescue/`).
2. **The USB stick copy is verified** - every artifact and every source file is
   accounted for (`/mbp-rescue/JOHNNY DISK USB/`).
3. **The secrets bundle has been opened.** `wave5-SECRETS-2026-10-20.tar.gpg`
   is on TeraBox but has never been decrypted. Download it, decrypt it and
   check the contents **before** the wipe. This is the one open item.
4. **You know where your SSH keys, API tokens and `.env` files are** and have
   copies somewhere that is not this laptop.
5. **The firmware password status is known.** Run `sudo firmwarepasswd -check`
   on the OLD macOS. If a firmware password is set, you must know it: a
   firmware password can block Option-boot, which is one of your ways back in.
6. **The battery decision is made** (see the battery table in section 11).
7. **The OpenSSH public key you want to use is in `~/.ssh/authorized_keys`** on
   the old machine - the bootstrap copies it to the new one.
8. **You have the TeraBox credentials and a Tailscale account** ready.

---

## 4. The DRY-BOOT test (do this before erasing anything)

The point is to prove the hardware works under Linux **without touching the
storage**.

1. Write the installer to the USB stick:
   `bash mac-prep/make-installer-usb.sh` (on the old Mac).
2. Plug the stick into the MacBook, hold **Option (Alt)** and boot.
3. In the installer menu choose "Try Ubuntu" (or "Install Ubuntu" - do NOT
   click through to the partition screen).
4. In the live session, test:
   * **Internal keyboard**: does it type? (The Apple internal keyboard needs
     the `hid-apple` driver; there is no separate `kbd-apple` module on modern
     kernels. If it does not type, that is the single most important thing to
     know now.)
   * **Wi-Fi**: join a network from the "Network" screen. Note the speed - the
     generic BCM4350 firmware is widely reported to be slow and the Apple
     board files faster, but that was never measured on this machine.
   * **Ethernet**: plug in the USB-C hub's Ethernet adapter, check the "Network"
     screen for a wired connection.
   * **Video**: if you brought a monitor through the HDMI adapter, does the
     installer screen appear on it?
   * **Sound**: not important for a hub.
5. **Never confirm storage.** Do not click "Erase disk and install". If you do
   reach the partitioner, back out.

If the internal keyboard does not work, plan on the install routes in the next
section instead.

---

## 5. Install routes

Pick one.

### Route A - internal keyboard

Boot from the USB stick with Option held, start the installer, answer the
questions below, let it finish, reboot, remove the stick.

### Route B - phone over SSH, using the installer's throw-away user

If the internal keyboard does not work but the installer has a network:

1. Choose "Try Ubuntu" (not "Install") - the live session has a throw-away
   user `ubuntu` with the password `ubuntu`.
2. From your phone (or another computer), SSH in:
   `ssh ubuntu@<live-session-ip>` and run `sudo cloud-init status --wait`.
3. In the live session, run the installer **non-interactively** with a
   preseed file so that no keyboard is needed. Write the preseed from the
   phone (or copy it in over SSH), then:
   `sudo ubuntu-install -- unattended preseed /path/to/preseed.cfg`
4. Reboot.

The preseed answers are the same as section 6 below.

### Route C - a cheap USB-C keyboard

A $10 USB-C keyboard is the cheapest way to survive the partitioner screen.
Plug it into the hub before you start and use it for the installer only.

---

## 6. Installer answers

| Screen | Answer |
|---|---|
| Installation type | Erase the whole internal SSD (the 500 GB Apple SSD), **not** "alongside" |
| Partitioning | "Use an entire disk" / manual: GPT, **1 GB EFI**, rest **ext4** on `/`, **no swap partition** (zram is used instead) |
| LVM | **No** |
| Root encryption | **No** (the vault container handles secrets) |
| Hostname | `mbp-hub` |
| User | `johnny` with your own strong password (sudo rights) |
| Network | the Wi-Fi network, or the Ethernet adapter |
| Proxy | none |
| Software selection | "Minimal" / "Standard server" - **no snaps** (uncheck the Snap options; the installer may not offer snaps at all on the server image) |
| OpenSSH server | **Yes** (import an authorized key now: the key from `~/.ssh/authorized_keys` on the old Mac) |
| Full-disk encryption for the LUKS container | not at install time - that is the vault, later |
| Done | reboot, remove the USB stick |

---

## 7. Boot tests (right after the first boot)

1. `lsb_release -a` -> 26.04.1, codename `resolute`.
2. `systemd-analyze time` - how long does it take to reach multi-user?
3. `ip -brief address` - is the network up?
4. `ping -c1 deb.debian.org` and `getent hosts archive.ubuntu.com` - DNS and routing.
5. `ssh <your-phone-or-laptop>` -> can you log in as `johnny`?
6. `systemctl --failed` - anything broken?
7. `journalctl -b -p err` - errors during boot.
8. Wi-Fi speed check (`iw dev wlp2s0 link` shows the negotiated rate). If it is
   slow, install the Apple board files (section 8).
9. Temperature under load: `hub-throttle-check` (after the bootstrap).

---

## 8. First 30 minutes

```bash
# 1. copy the kit to the new box and run it
git clone https://github.com/jonquixote/mbp-hub.git
cd mbp-hub
bash bootstrap/bootstrap.sh

# 2. check that everything is sane
hub-status

# 3. optional modules, one at a time
sudo bash bootstrap/optional/04-wifi.sh          # WIFI_SSID / WIFI_PASS
sudo bash bootstrap/optional/20-jellyfin.sh
sudo bash bootstrap/optional/40-vault.sh
sudo bash bootstrap/optional/45-wifi-firmware.sh <dir>
```

Then the manual steps that no script should do for you:

* **Tailscale admin**: open the admin console, approve the node, approve the
  `tag:hub` tag request, paste `policy/tailscale-policy-snippet.json` into the
  policy editor and run the policy tester.
* **Set the host name and time zone** (the bootstrap does the time zone).
* **Put the secrets in the vault** (section 9).
* **Decide about the Wi-Fi firmware** and run `45-wifi-firmware.sh` with the
  three `brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.*` files.

---

## 9. Vault workflow

The vault is a LUKS2 container file at `/var/lib/vault/vault.img` holding an
ext4 filesystem that is mounted at `/vault`. It is opened by hand and never
automatically.

```bash
sudo vault-open          # you type the passphrase
ls /vault/johnny         # your SSH keys, API tokens, .env files
cp /vault/johnny/id_ed25519 ~/.ssh/     # copy what you need out
sudo vault-close         # lock it again
```

What is **in** the vault: SSH private keys, API tokens, `.env` files.

What stays on the **unencrypted root** (and has to, so the machine is
reachable while the vault is closed): Tailscale state (`/var/lib/tailscale`),
SSH host keys (`/etc/ssh`), the `agent` account, the restic repository
credentials if you put them in `/etc/hub/restic.env`.

The `agent` user has no password and no sudo. `agent-start` refuses to run
while the vault is closed, because the agent's secrets are inside it.

**Losing the passphrase loses the vault.** There is no recovery path.

---

## 10. Acceptance checklist

Every line must be true before you call the hub "done".

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | OS version | `lsb_release -a` | 26.04.1, resolute |
| 2 | SSH hardening | `sudo sshd -T \| grep -E 'passwordauthentication\|kbdinteractive\|permitrootlogin\|authenticationmethods\|maxauthtries'` | no / no / no / publickey / 3 |
| 3 | Authorized keys | `sudo ls -l /etc/ssh/authorized_keys.d/` | root:root 0644, one file per user |
| 4 | Firewall | `sudo ufw status verbose` | default deny incoming, tailscale0 allowed, LAN CIDR allowed for 22, 60000:61000/udp, 8096, 1900/udp, 7359/udp |
| 5 | Power restore **read** | `sudo hub-power-restore --check` | prints the LPC bridge BDF and the `0xa4` byte |
| 6 | **Plug-pull test** | unplug the charger for 10 s, plug it back in | the hub comes back by itself (this is the real test - see KNOWN UNKNOWNS) |
| 7 | Throttle check | `sudo hub-throttle-check` | record the verdict verbatim: "No PROCHOT observed during the test." **or** "PROCHOT WAS ASSERTED during the test." **or** "UNKNOWN - the MSR could not be read, so no verdict is possible." A PROCHOT verdict must be investigated (battery first), not silently accepted |
| 8 | Battery reporting | `upower -i $(upower -e \| grep BAT)` | state and percentage, no error |
| 9 | Vault open | `sudo vault-open` | mounted at /vault, /vault/johnny and /vault/agent present |
| 10 | Vault close | `sudo vault-close` | unmounted, mapper gone, `vault-status` says closed |
| 11 | Vault is really encrypted | `sudo blkid /var/lib/vault/vault.img` | says `crypto_LUKS` |
| 12 | Restore test | `sudo hub-restore-test` | "restore test OK" |
| 13 | Tagged node | `tailscale status \| grep mbp-hub` | the node shows `tag:hub` |
| 14 | Firmware password | (not runnable on Linux - `firmwarepasswd` is macOS-only) | confirmed on the OLD Mac in the pre-wipe checklist, step 5; the hub has no firmware password of its own |
| 15 | Jellyfin | `systemctl is-active jellyfin` + open the web UI | active, library reachable |
| 16 | Private media access | `sudo tailscale serve --bg 8096` | reachable from your phone over the tailnet, and **not** from the public internet |
| 17 | No Docker in the core | `systemctl is-active docker` | inactive unless you ran 05-docker.sh |
| 18 | Lid closed | close the lid and wait | the hub keeps running (logind ignores the lid) |
| 19 | Reboot policy | `systemctl list-timers \| grep hub-reboot` | the daily 04:30 timer exists |
| 20 | Wi-Fi firmware | `dmesg \| grep -i brcmfmac` | the Apple board files are loaded, if you installed them |

---

## 11. Battery decision table

The battery in this MacBook reports **Service Recommended** and is at
**43.97 %** health (2106 mAh of a 4790 mAh design capacity, 838 cycles).

| Situation | What happens | What to do |
|---|---|---|
| Battery in the machine, charger connected | Expected normal operation - **no throttling measured**. TODO(verify): run `hub-throttle-check` to confirm (known unknown 5) | Keep it. This is the recommended state. |
| Battery in the machine, service-required, on battery | Shorter runtime, possibly reduced performance | Order a replacement battery, or keep it on AC |
| Battery removed, charger connected | **PROCHOT is asserted, the CPU is throttled hard** - this is the firmware's way of saying "no battery, no performance" | Do not remove the battery just to "clean it up". Replace it, or accept a slow machine |
| Battery removed, charger disconnected | The machine dies immediately | Obviously not |
| Any state | **Never disable PROCHOT** | It is the firmware's safety mechanism. Disabling it turns a slow machine into an unstable one |

The kit is battery-aware but deliberately does **not** touch PROCHOT:
`44-tune-lowpower.sh` only reads MSR `0x19c` (IA32_THERM_STATUS) to show you
whether throttling is happening.

---

## 12. Day-2 (the boring parts that keep it alive)

* **Reboot policy**: a daily timer at 04:30 checks whether
  `/var/run/reboot-required` has been pending for 21 days or more, and only
  then reboots. Create `/etc/hub-no-auto-reboot` to block it entirely.
* **Unattended upgrades**: security and `-updates` origins, no automatic
  reboot, unused kernels removed. `needrestart` restarts services after
  updates but never `ssh` or `tailscaled`.
* **Backups**: restic, weekly, `keep-weekly 8` / `keep-monthly 6`, with a
  monthly `restic check --read-data-subset=5%` and a manual
  `hub-restore-test` that restores the latest snapshot and compares it.
* **Heartbeat**: every 5 minutes the hub pings your heartbeat URL. If the node
  has no Tailscale address it pings the `/fail` variant, so "hub offline" and
  "hub up but not connected" are different signals.
* **Journal**: capped at 500 MB.
* **Zram**: `min(ram/2, 4096)` MiB with zstd.
* **Sensors**: `thermald` and `mbpfan` enabled; `lm-sensors` for reading them.

---

## 13. Security model

**Trust boundaries**

| Zone | Trust | Contents |
|---|---|---|
| Tailscale tailnet | Your devices only | The only way in from outside the house |
| LAN (ufw-allowed ports) | Semi-trusted | SSH, mosh, Jellyfin, DLNA |
| Public internet | Untrusted | Nothing. Tailscale only. **No Funnel.** |
| `/` (unencrypted root) | Trusted, but readable if the disk is stolen | Tailscale state, SSH host keys, service configs |
| `/vault` (LUKS2) | Secret | SSH private keys, API tokens, `.env` files |

**Rules the kit follows**

* No password login, no root login, publickey only, `MaxAuthTries 3`.
* `agent` has no password, no sudo, and cannot work until a human unlocks the
  vault.
* Secrets are never in this repository. They are passed as environment
  variables, or placed in root-owned `0600` files on the box
  (`/etc/hub/restic.env`, `/etc/hub/heartbeat.env`).
* No sudoers rules are written.
* Docker is optional and off by default; if you enable it, remember that
  published ports bypass ufw.
* `tailscale serve` (private) is fine; `tailscale funnel` (public) is not.

**Residual risks**

* The LUKS passphrase protects the vault, not the whole disk. A stolen,
  unbooted disk still leaks the Tailscale state and the SSH host keys.
* RustDesk's unattended-access password is stored by RustDesk itself on the
  unencrypted root.
* The restic repository password is stored on the box in a `0600` file (that
  is how restic is designed to work). Use a repository password that is
  worthless on its own.
* The firmware password status of the old machine is unknown until you check
  it.

---

## 14. KNOWN UNKNOWNS

Things this kit could not verify, with the test that would settle each one.

| Unknown | Why it is unknown | How to settle it |
|---|---|---|
| Does the hub auto-start after an AC power cut? | `setpci 0xa4` bit semantics are documented for other Macs, not confirmed for 14,1 | Plug-pull test (acceptance check 6) |
| Is the `0xa4` guard's polarity right? | The kit writes `0xa4.b=0:1` when bit 0 is *already* set, as specified | Read the value before and after; compare with the plug-pull result |
| Does the internal keyboard work under Linux? | The live-installer test has not been run on this machine | DRY-BOOT test (section 4) |
| How fast is the Wi-Fi with the Apple board files, and is the board-file *name* right? | The board files are not on the box yet, and the name is derived from the brcmfmac convention rather than read off the hardware | Install them, then compare `iw dev wlp2s0 link` |
| Is the CPU throttled by PROCHOT with the battery in place? | The battery reports service-required; behaviour on Linux is unknown | `hub-throttle-check` |
| Does `BCLM`/`BFCL` exist on this MacBook's SMC? | Read from the upstream source only, never tested | `sudo ./macbook-charge-limit read` on a Linux box |
| Is the zram-generator `min(ram/2, 4096)` expression accepted on the real box? | It was accepted by the generator in the 26.04 container, but never confirmed with this machine's 16 GB of RAM | `sudo zramctl` and `journalctl -u systemd-zram-generator` |
| Does the Ubuntu Pro `resolute-infra-pro` repository exist? | The client is installed from the official PPA, but the ESM repo path is inferred | `sudo pro status` after attaching |
| Is Livepatch available for the 26.04 kernel? | Depends on Canonical's coverage, not on this kit | `pro status` |
| Does the Tailscale policy snippet pass the admin policy tester? | It is a snippet, not a whole policy | Paste it into the admin editor and run the tester (section 8) |
| Is the GitHub repo name `mbp-hub` free? | Checked at publish time | The publish step says which name was used |
| Do the Jellyfin hardware transcoding steps work on this Kaby Lake CPU? | The i5-7360U (Kaby Lake, Iris Plus Graphics 640) lists Quick Sync Video in Intel's specification, but the Linux driver has not been checked on this machine | `vainfo` output from `20-jellyfin.sh`, then transcode one file |
| Is Jellyfin in the Ubuntu 26.04 archive? | **No** - `apt-cache policy jellyfin` finds nothing in the archive, so Jellyfin and `jellyfin-ffmpeg*` come from `repo.jellyfin.org` (added by Jellyfin's own install script) | `apt-cache policy jellyfin` after the module ran |
| Is the GPG signature of the ISO verifiable on the Mac? | Needs the Ubuntu archive keyring | Install `ubuntu-keyring` and re-run the mac-prep script |
| Does `sudo -E` preserve the environment on sudo-rs? | **Mostly resolved**: `sudo -E` is documented as ignored by sudo-rs ("preserving the entire environment is not supported"), so the kit uses `sudo --preserve-env=VAR1,VAR2` (verified working in the container) or `/etc/hub/optional.env`. TODO(verify): the sudo implementation and version on the real box - the container test ran as root, so the ignore-message was not reproduced there | `sudo --version` on the hub |
