# mbp-hub

A kit that turns a 2017 13" MacBook Pro (**MacBookPro14,1**) into a headless
Ubuntu Server 26.04.1 LTS "hub": SSH + Tailscale for access, Jellyfin for
media, a LUKS vault for secrets, restic for backups, and a set of small
optional modules you enable one at a time.

Built for one machine, with the facts about that machine baked in.

* **Target:** MacBookPro14,1 (13", 2x USB-C, no Ethernet jack, no Touch Bar, no T1/T2)
* **CPU:** Intel Core i5-7360U, 2 cores / 4 threads (measured on this machine).
  The part is a **Kaby Lake** chip - that is inferred from the model number,
  not from a field the machine reports.
* **GPU:** Intel Iris Plus Graphics 640, PCI device ID `0x5926` (measured on
  this machine)
* **Base OS:** Ubuntu Server 26.04.1 LTS (codename `resolute`), headless, remote-first
* **Wi-Fi chip:** Broadcom BCM4350 (PCI `14e4:43a3` rev `0x05`, subsystem
  `0x106b:0x0170`, measured on this machine). The board files are *expected* to
  be `brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.{bin,clm_blob,txcap_blob}` -
  that name is derived from the brcmfmac convention, not confirmed on this box.
* **Battery:** reports *Service Recommended* (43.97 % health). The kit is
  battery-aware and **never disables PROCHOT**.

## There are no secrets in this repo

**No secrets in this repo.** No tokens, no passwords, no keys, no real
hostnames, no real IP addresses, no real SSIDs. Every secret is passed to the
scripts as an environment variable, or is created by you on the target box in
a root-owned `0600` file. The secret scan in the test phase is part of the
release checklist.

| Variable | Used by | What it is |
|---|---|---|
| `UBUNTU_PRO_TOKEN` | `bootstrap.sh` | Ubuntu Pro token (piped to `pro attach` on stdin, never in argv) |
| `TS_AUTHKEY` | `bootstrap.sh` | Tailscale auth key (passed through argv, so it is visible in `ps` while `tailscale up` runs) |
| `TS_TAG` | `bootstrap.sh` | Tailscale tag to request, e.g. `tag:hub` |
| `HC_URL` | `bootstrap.sh` | heartbeat URL (stored on the box as `0600` `/etc/hub/heartbeat.env`) |
| `WIFI_SSID`, `WIFI_PASS` | `04-wifi.sh` | wireless network |
| `RD_PASS` | `30-gui-rustdesk.sh` | RustDesk unattended-access password |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE` | `41-backup-restic.sh` | **no defaults**: you create `/etc/hub/restic.env` yourself |

Two ways to give a module its secrets:

```bash
# 1. the environment (do NOT rely on "sudo -E" - name the variables):
sudo --preserve-env=WIFI_SSID,WIFI_PASS bash bootstrap/optional/04-wifi.sh

# 2. a root-owned file the module reads (mode 0600, never committed):
sudo install -d -m 0700 /etc/hub
sudo install -o root -g root -m 0600 /dev/null /etc/hub/optional.env
sudoedit /etc/hub/optional.env
sudo bash bootstrap/optional/04-wifi.sh
```

## Layout

```
mbp-hub/
  README.md                        this file
  RUNBOOK.md                       the full human procedure: dry-boot, install, acceptance
  mac-prep/
    make-installer-usb.sh          macOS: download + SHA256-verify the ISO, write it to a USB stick
  bootstrap/
    bootstrap.sh                   the 12-step bootstrap (run as your normal user)
    optional/
      04-wifi.sh                   netplan wireless from WIFI_SSID / WIFI_PASS
      05-docker.sh                 docker.io + compose v2 (optional; Jellyfin does NOT need it)
      10-agents.sh                 claude + opencode for the unprivileged 'agent' user
      20-jellyfin.sh               Jellyfin, native, from Jellyfin's own apt repo
      30-gui-rustdesk.sh           XFCE + RustDesk (heavy, optional)
      40-vault.sh                  LUKS2 container file, ext4 inside, mounted at /vault
      41-backup-restic.sh          weekly restic backups, monthly integrity check
      42-media-mount.sh            add a media disk to /etc/fstab by UUID (nofail)
      43-battery-limit.sh          battery report; it only installs the notes file, and it writes the kernel charge threshold if you pass a percentage
      44-tune-lowpower.sh          balance_power unit + hub-audit + hub-throttle-check
      45-wifi-firmware.sh          install the Apple BCM4350 board files
  docs/
    battery-charge-limit-notes.md  what the third-party SMC tool does, and what it risks
  policy/
    tailscale-policy-snippet.json  tag + ACL + Tailscale SSH policy snippet
  tests/
    run-container-tests.sh         reproduces every check from the test phase
    secret-scan.sh                 scans the repo for tokens, keys, IPs, SSIDs
```

## Quick start on the new box

```bash
git clone https://github.com/jonquixote/mbp-hub.git
cd mbp-hub
bash bootstrap/bootstrap.sh
hub-status
```

Then the optional modules, one at a time, as root:

```bash
sudo bash bootstrap/optional/04-wifi.sh
sudo bash bootstrap/optional/20-jellyfin.sh
sudo bash bootstrap/optional/40-vault.sh
sudo bash bootstrap/optional/41-backup-restic.sh
sudo bash bootstrap/optional/45-wifi-firmware.sh /path/to/the/dir/with/the/three/files
```

`RUNBOOK.md` has the whole procedure, including the **dry-boot test before you
erase anything** and the acceptance checklist.

## The Tailscale policy snippet

`policy/tailscale-policy-snippet.json` is a **snippet, not a whole policy**:

* paste it into the Tailscale admin policy editor
  (<https://login.tailscale.com/admin/acls>), merging it with whatever you
  already have
* **check it with the policy tester** in that editor before you rely on it
* `tagOwners` gives you ownership of `tag:hub`; the ACL lets only
  `autogroup:admin` (your own devices) reach `tag:hub`; the SSH rule allows
  Tailscale SSH to `tag:hub` for the users `johnny` and `agent`
* **tagging is one-way**: once a node is tagged `tag:hub` it can only be
  re-tagged by a tag owner, and removing the tag is what you do to take the
  node out of the group. Read the Tailscale docs before you paste it.
* the `tests` section contains placeholder hostnames - replace them with your
  own device names before using the tester

## Tests

```bash
# anywhere with Docker (the Mac, or the Linux box):
bash tests/run-container-tests.sh
```

The checks always run inside an `ubuntu:26.04` container - the script refuses
to run natively, because it installs packages and writes to `/etc` while it
works.

It checks: `bash -n` and shellcheck on every script, every package name it
can check against the 26.04 archive (the vendor-repo packages, plus
`intel-media-va-driver*` and `e2fsprogs`, are listed but not archive-checked),
the coreutils/sed/awk behaviour the scripts rely on most, unit tests for the
reboot policy and the heartbeat, the PROCHOT/thermal check (the right MSR
address, hex parsing, and the bit that means "PROCHOT event"), and validates
the generated configuration (`sshd -t`, `netplan generate`,
`systemd-analyze verify`, JSON validity). The secret scan runs last.

The result of the last run is in `TEST-REPORT.md` in the build directory (not
in this repo). TODO(verify): it was written against an earlier revision of
this kit - re-run the suite before you trust it.

## Ubuntu 26.04 specifics this kit had to respect

* **sudo-rs** is the default `sudo` on 26.04, and `sudo -E` is ignored by it:
  during the test phase, in-container as a non-root user, sudo-rs 0.2.13
  printed "preserving the entire environment is not supported, '-E' is
  ignored". So the kit uses `sudo --preserve-env=VAR1,VAR2` and a root-owned
  `0600` env file instead. TODO(verify): the sudo implementation and version
  on the real box - the shipped harness runs as root, where `-E` appeared to
  keep the variable, so the ignore-message is not reproduced there.
* **uutils coreutils** replace GNU coreutils for everything except `cp`, `df`,
  `mv`, `rm` and `true`. The coreutils calls the kit relies on most (`stat`,
  `date`, `install`, `cut`, `head`, `tee`, `sed -i`, `awk`, `mktemp`, `tr`,
  `seq`, `sha256sum`, `du`, `grep -c`) are listed in the test phase and were
  run against the real 26.04 utilities. TODO(verify): the remaining calls
  (`dirname`, `chmod`, `chown`, `mkdir`, `touch`, `cat`, `cmp`, `truncate`,
  `basename`, `sleep`) are not individually exercised, and the harness does
  not assert that `cp`/`df`/`mv`/`rm`/`true` are the GNU builds.
* **No sudoers rules** are written by this kit.
* Jellyfin runs **natively** from Jellyfin's apt repository. Docker is
  optional and off by default.

## TODO(verify) - things this kit could NOT prove

Every item here is either marked in the code with a `TODO(verify):` comment or
is listed in `RUNBOOK.md` under *KNOWN UNKNOWNS*. None of them is presented
as a fact.

1. **GPG verification of the ISO** needs the Ubuntu archive keyring on the
   Mac (`make-installer-usb.sh`). Without it the signature check reports "no
   public key" and continues - the SHA256 is the hard gate.
2. **The `0xa4` bit-0 guard** in `hub-power-restore` is implemented exactly as
   specified (write when bit 0 is *already* set), but the polarity of that bit
   for auto-restart-after-AC-loss on this MacBook is unconfirmed. Settle it
   with the **plug-pull test** in the acceptance checklist.
3. **`BCLM` / `BFCL` SMC keys** - that they exist and behave as described in
   `docs/battery-charge-limit-notes.md` was read from the upstream source, not
   tested on this hardware.
4. **Whether macOS honours a charge limit left behind by Linux** - not
   tested; inferred from the SMC key semantics.
5. **The upstream commit** the notes were written against
   (`9bb39ab4ee03f59688cd36e3695b0a0ea8c25e2e`) may move.
6. **Whether the internal keyboard works under Linux** - needs the dry-boot
   test.
7. **How fast the Wi-Fi is with the Apple board files** - needs the files and
   a measurement. The board-file *name* is also derived from the brcmfmac
   convention rather than read off the hardware.
8. **Whether the CPU is throttled by PROCHOT with the battery in place** -
   needs `hub-throttle-check` on the real machine.
9. **The Ubuntu Pro ESM repository path** for `resolute` is inferred from the
   codename; the client itself comes from the official PPA. Check with
   `pro status` after attaching.
10. **Livepatch coverage** for the 26.04 kernel is Canonical's call, not this
    kit's.
11. **The Jellyfin hardware transcoding path** on this Kaby Lake CPU - Intel's
    specification lists Quick Sync Video for the i5-7360U, but the Linux driver
    has not been checked - check the `vainfo` output that `20-jellyfin.sh`
    prints, then transcode one file. Which VAAPI codecs the *free* Intel
    driver exposes on this Iris Plus 640 is equally unproven.
12. **The policy snippet** has to be validated with the Tailscale admin policy
    tester before it is trusted.
13. **The GitHub repository name** `mbp-hub` may already be taken - the publish
    step reports which name was actually used.
14. **The zram-generator `min(ram/2, 4096)` expression on the real box** - it
    was accepted in the 26.04 container; confirm with `sudo zramctl` on this
    16 GB machine.
15. **The sudo implementation and version** on the 26.04 image - the container
    test ran as root, so the `-E` ignore-message was not reproduced. Check
    `sudo --version` on the real box.
16. **The Tailscale auth key passes through argv** in `tailscale up`, so it is
    visible in the process list while that command runs. Run `tailscale up` by
    hand and paste the key if that matters to you.
17. **The needrestart version** on the real box - the config was validated
    with `perl -c` and `needrestart -b` in the container, but the version was
    not recorded.
18. **`TEST-REPORT.md` is from an earlier revision** of this kit - re-run the
    suite before you trust the numbers in it.
19. **The coreutils calls the harness does not exercise** (`dirname`, `chmod`,
    `chown`, `mkdir`, `touch`, `cat`, `cmp`, `truncate`, `basename`, `sleep`),
    and whether `cp`/`df`/`mv`/`rm`/`true` really are the GNU builds.
20. **Whether the upstream `apple_mc` `charge_control_end_threshold` patch has
    landed** - the notes describe one upstream commit and may be stale.

## Licence

Do what you want with it, but check the licences of anything you add: the
vendors' installers it calls (Tailscale, Jellyfin, RustDesk, Claude Code,
opencode) keep their own.
