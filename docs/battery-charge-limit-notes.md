# Battery charge limit on Linux - notes on `jtbrough/macbook-charge-limit`

These notes were produced by **reading the source** of
<https://github.com/jtbrough/macbook-charge-limit> (README, `Makefile`,
`src/macbook-charge-limit.c`, `packaging/systemd/macbook-charge-limit.service.in`,
commit `9bb39ab4ee03f59688cd36e3695b0a0ea8c25e2e`). The project was **not
downloaded, built or executed** on the Mac and is **not** installed by this kit.

## What it claims

"Set an Intel MacBook battery charge limit from Linux via Apple SMC keys."
Linux does not expose the standard `charge_control_end_threshold` sysfs
interface for MacBook batteries, so the project writes the Apple SMC keys
`BCLM` (Battery Charge Level Max) and `BFCL` (battery final charge level)
directly.

## What it actually does (from the source)

| Item | Finding |
|---|---|
| Language / size | C, single file ~7.8 KB, MIT licensed |
| Mechanism | Direct I/O port access to the Apple SMC: data port `0x300`, command port `0x304`; `ioperm()` with `CAP_SYS_RAWIO`, so it must run as root |
| Keys written | Exactly two, both 8-bit: `BCLM` and `BFCL`. `set <20..100>` writes the percentage to both; `reset` writes `100` to both |
| Keys read | `read` prints `BCLM=<n> BFCL=<n>` |
| Guard rails | Refuses to run unless DMI `sys_vendor` is exactly `Apple Inc.` **and** `product_name` starts with `MacBook`. "MacBookPro14,1" does start with "MacBook", so **it would run on this machine**. It does not expose arbitrary SMC writes |
| Files it installs | `/usr/local/bin/macbook-charge-limit`, `/etc/macbook-charge-limit.conf` (mode 0644, only created if absent), `/etc/systemd/system/macbook-charge-limit.service` |
| Service behaviour | oneshot, `RemainAfterExit=yes`, `WantedBy=multi-user.target`, runs `macbook-charge-limit set ${LIMIT}` at every boot; `LIMIT` defaults to **80** and can be overridden in `/etc/macbook-charge-limit.conf` |
| Kernel modules | None. It is a pure userspace workaround - no `apple_mc` patch, no driver |
| Upstream direction | The README links two upstream changes (an `apple_mc` `charge_control_end_threshold` patch and a UPower fix). Once those land in a distro kernel, this tool is unnecessary. TODO(verify): whether either has since landed - the notes above describe one upstream commit (`9bb39ab4ee03f59688cd36e3695b0a0ea8c25e2e`) and may be stale |

## Risks and side effects

1. **Raw SMC I/O as root.** The tool pokes the SMC over I/O ports with no
   kernel mediation. A bug in it can write unexpected SMC values. The code is
   short and readable, and it only ever touches `BCLM`/`BFCL`, which limits the
   blast radius - but it is still unsupported, out-of-tree code running as root
   on every boot.
2. **The limit persists in SMC NVRAM.** `BCLM`/`BFCL` are not reset by a
   reboot. If the same MacBook is later booted into **macOS**, macOS will see
   the same charge limit and will stop charging at that percentage until the
   limit is cleared (`sudo macbook-charge-limit reset` from Linux, or a
   service reset from macOS). For a machine being sold or re-used, that is a
   real surprise.
3. **It writes a persistent systemd unit** that rewrites the SMC keys on every
   boot. If the tool is later removed without running `reset` first, the limit
   stays in the SMC.
4. **Not packaged by Ubuntu.** No apt package, no signature, no distro
   security review. It would be built from source on the machine.
5. **Tested on other hardware only.** The README lists `MacBookAir6,2` on
   CachyOS. Nothing in the source is 14,1-specific, but the SMC key support
   for `BCLM`/`BFCL` on MacBookPro14,1 is **not verified** by the project.

## The safe path for this kit

This kit does **not** install this project. `43-battery-limit.sh` is read-only
by default and only uses the kernel's own interface:

* if `/sys/class/power_supply/BAT*/charge_control_end_threshold` exists, the
  module can install a tiny systemd unit that writes a threshold into that
  sysfs file (the supported, kernel-mediated way);
* if it does not exist, the module says so and changes nothing.

On a stock Ubuntu 26.04 kernel the file is expected to be **absent** for a
MacBook, because the `apple_mc` driver does not implement the threshold
interface. TODO(verify): that the upstream `charge_control_end_threshold`
patch has still not landed - the notes above describe one upstream commit
(`9bb39ab4ee03f59688cd36e3695b0a0ea8c25e2e`) and may be stale. Expect the
"not available" branch, and expect `hub-throttle-check` to remain the useful
tool.

## What this kit does about throttling instead

The battery in this MacBook reports **Service Recommended** and is at
**43.97 %** health. With the battery removed, the Apple firmware asserts
**PROCHOT** and the CPU throttles hard. The kit's approach:

* **keep** the battery in the machine, or **replace** it - do not remove it
  and do not disable PROCHOT;
* `hub-throttle-check` reads MSR `0x19c` (IA32_THERM_STATUS: bit 0 = Thermal
  Monitor Status, bit 3 = PROCHOT#/FORCEPR# event, bit 5 = the sticky PROCHOT
  log) before and after a 60 second all-core load, so a throttle can be *seen*
  rather than guessed;
* `hub-audit` reports what is running, for comparison.

## If you decide to use it anyway

```
git clone https://github.com/jtbrough/macbook-charge-limit.git
cd macbook-charge-limit
make
sudo ./macbook-charge-limit read        # read-only, safe
sudo ./macbook-charge-limit set 80      # writes BCLM and BFCL
sudo ./macbook-charge-limit reset       # write 100 to both - DO THIS before selling the Mac
```

Run it with the vendor's upstream README, and make sure `reset` is executed
before the machine leaves your hands.

## TODO(verify)

* TODO(verify): that `BCLM`/`BFCL` exist and behave as expected on
  MacBookPro14,1 - only read from the source, never tested on the hardware.
* TODO(verify): whether macOS honours a limit left behind by Linux - not
  tested, reason from the SMC key semantics only.
* TODO(verify): the exact current commit of the upstream repository - the
  notes above describe commit `9bb39ab4ee03f59688cd36e3695b0a0ea8c25e2e`.
