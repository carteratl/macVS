# macVS

Durable Debian virtual servers on Apple Silicon Macs.

One command creates a **Debian 13 (trixie)** server that boots with the Mac, restarts
after a crash, powers off cleanly at shutdown, serves the web ports, and gives idle
memory back to macOS. It runs under QEMU with Apple's Hypervisor.framework, is
configured unattended by cloud-init on first boot, and is supervised by launchd.
Existing QEMU disk images can be adopted with `macvs import`.

```
$ macvs create web
==> creating 25G disk from debian-13-generic-arm64.qcow2
==> building cloud-init seed (user 'admin', hostname 'web')
 ok  created web in /Users/you/.macvs/vms/web
==> installing LaunchDaemon /Library/LaunchDaemons/com.carteratl.macvs.web.plist (sudo will prompt for your password)
 ok  web is now managed by launchd (system): label com.carteratl.macvs.web, pid 41272
 ok  SSH is up after 6s
 ok  cloud-init: done

Connect:  macvs ssh web
```

Stage one of the project: it produces a clean Debian server and manages its lifecycle.
Web stacks and other provisioning are deliberately left to you (or to a later stage).

## Requirements

- An Apple Silicon Mac (arm64) with virtualization enabled (`sysctl kern.hv_support` is `1`).
- [Homebrew](https://brew.sh) and QEMU: `brew install qemu` (tested with QEMU 11.1 on macOS 26).
- Nothing else. Image download and verification, the cloud-init seed, SSH, and the
  service integration use only tools that ship with macOS. The CLI is bash 3.2, the
  version macOS ships. Root is not required to run VMs or to serve ports 80 and 443;
  sudo is used once per VM to install its boot-time launchd job.
- Optional: `brew install openssl@3` to use `--password`.

## Install

```bash
git clone https://github.com/carteratl/macVS.git ~/macVS
cd ~/macVS && ./install.sh
```

`install.sh` copies the tool to `~/.macvs/app`, links `macvs` into `/opt/homebrew/bin`
(or `~/.local/bin`), writes a commented default config to `~/.macvs/config`, and runs
`macvs doctor`. It installs a copy instead of linking the clone because launchd cannot
execute anything under `~/Documents`, `~/Desktop`, `~/Downloads`, or iCloud Drive
(macOS privacy controls answer "Operation not permitted"), so the clone can live anywhere.
After `git pull`, run `./install.sh` again. `./install.sh --uninstall` removes the tool
and leaves VM data alone.

## Quick start

```bash
macvs create web                # image (once), create, register with launchd, boot, wait
macvs ssh web                   # log in as 'admin' (passwordless sudo)
macvs status web
macvs stop web                  # clean ACPI power-off; comes back at next boot
macvs autostart web off         # park it: stays off until 'macvs start web'
macvs destroy web --yes
```

### What `create` does by default

- Forwards SSH (first free port from 2222) plus **80 and 443** from all of the Mac's
  addresses to the guest. Only one VM can own a host port, so a second VM needs
  `--no-web` (or other `--forward` values); `create` refuses conflicts up front.
- Registers a **system LaunchDaemon** (sudo prompts once) so the VM boots with the Mac,
  before anyone logs in, and restarts after a crash. QEMU still runs as your user.
- Gives the guest 2 vCPUs and 2048 MiB with a **virtio balloon**, so memory the guest
  frees is returned to macOS within seconds instead of staying pinned.
- Waits until SSH answers and cloud-init reports done, then prints how to connect.

Options (defaults in parentheses; all overridable in `~/.macvs/config`):

| Option | Meaning |
|---|---|
| `--cpus N` | vCPUs (2) |
| `--memory MiB` | RAM ceiling (2048) |
| `--disk SIZE` | virtual disk, grown on first boot (25G) |
| `--ssh-port PORT` | host port forwarded to guest 22 (first free port from 2222) |
| `--forward H:G` | extra TCP forward host→guest; repeatable, e.g. `--forward 8080:8080` |
| `--no-web` | do not forward 80 and 443 |
| `--bind ADDR` | address forwards bind to (0.0.0.0; `127.0.0.1` keeps them on this Mac) |
| `--user NAME` | admin user created in the guest (admin) |
| `--ssh-key FILE.pub` | key to authorise (your `~/.ssh/id_ed25519.pub`, else a new per-VM key) |
| `--password` | prompt for a serial-console password; SSH stays key-only |
| `--timezone TZ` | guest timezone (this Mac's) |
| `--release NAME` | Debian codename (trixie = 13) |
| `--variant NAME` | cloud image variant: `generic` or `genericcloud` (generic) |
| `--cache MODE` | QEMU disk cache mode (writeback) |
| `--no-balloon` | disable the memory balloon |
| `--agent` | register a per-user LaunchAgent instead (starts at login, no sudo) |
| `--no-daemon` | create only; boot later with `macvs start` |
| `--no-wait` | do not wait for SSH and cloud-init |

## Importing an existing VM

```bash
macvs import ponder --disk ~/old/ponder.qcow2 --nvram ~/old/ponder-vars.fd --user josh --ssh-port 2222
```

`import` adopts a qcow2 you already have: it clones the disk and UEFI variable store
into `~/.macvs/vms/<name>` (instant on APFS; the originals are untouched unless you pass
`--move`), attaches no cloud-init seed, and then registers and boots the VM exactly like
`create`. It refuses a disk that a running QEMU still has open. Pass `--nvram` for systems
installed from an installer ISO, whose boot entry lives in that file; the Debian cloud
images and anything installed to the removable EFI path boot without it. `--ssh-key`
lets `macvs ssh` log in with a key; without one it will prompt for a password.
`--resize` grows the virtual disk (grow the guest filesystem yourself afterwards).
See [docs/MIGRATING.md](docs/MIGRATING.md) for a step-by-step migration from a
hand-built QEMU plist.

## Commands

| Command | What it does |
|---|---|
| `macvs create <name> [opts]` | Create a VM from the cached, checksum-verified Debian image |
| `macvs import <name> --disk F` | Adopt an existing qcow2 as a managed VM |
| `macvs start <name>` | Boot it (through launchd if it has a job, otherwise detached) |
| `macvs stop <name> [--force]` | ACPI power-off via QMP; escalates to quit/kill after the timeout |
| `macvs restart <name>` | Stop then start |
| `macvs autostart <name> [on\|off]` | Whether it boots with the Mac and restarts after a crash (on) |
| `macvs destroy <name> [--yes]` | Stop, remove the launchd job, delete `~/.macvs/vms/<name>` |
| `macvs list` / `macvs status <name>` | State, pid, uptime, ports, launchd status |
| `macvs ssh <name> [cmd]` | SSH with the right port, key, and a per-VM known_hosts file |
| `macvs ssh-config <name>` | Print a `Host` block for `~/.ssh/config` |
| `macvs console <name>` | Attach to the serial console (press Enter for a prompt, `Ctrl-]` to detach) |
| `macvs logs <name> [-f] [--console\|--qemu\|--launchd]` | Tail the console, QEMU, or launchd log |
| `macvs wait <name>` | Block until SSH answers (and cloud-init is done) |
| `macvs reseed <name>` | Rebuild the cloud-init seed after editing `vm.conf` (VM stopped) |
| `macvs daemon install <name> [--system\|--agent]` | Register with launchd (system needs sudo) |
| `macvs daemon uninstall\|status\|plist <name>` | Manage or inspect the launchd job |
| `macvs image pull [--refresh]` / `list` / `rm <release>` | Manage cached base images |
| `macvs doctor` | Check the Mac, including whether the web ports are free |
| `macvs run <name>` | Run QEMU in the foreground (this is what launchd executes) |

## Hosting internal websites

The intended pattern is one VM that owns ports 80 and 443 on the Mac, with the sites
inside it distinguished by name. Point names at the Mac and let the guest's web server
route by `Host` header or SNI:

- **From the Mac itself**, add lines to `/etc/hosts`:
  `127.0.0.1  ponder.test  wiki.ponder.test`. Use IPv4 entries only; the forwards
  listen on IPv4, so a `::1` line would make browsers try IPv6 first and fail over slowly.
- **From other machines**, point the same names at the Mac's LAN address in their hosts
  files or in your router's DNS. The default `--bind 0.0.0.0` makes that work without
  any other change.

Things to know:

- **Use names you own and real certificates.** The best setup is a domain you have
  registered, with Let's Encrypt certificates issued by certbot inside the guest. TLDs on
  browsers' HSTS preload list such as `.foo`, `.dev`, `.app`, and `.page` are a good fit:
  browsers insist on HTTPS for them, and with a valid certificate that is exactly what you
  want. Nothing on the clients needs configuring beyond the name resolution above.
- **Getting certificates from inside the VM.** Outbound traffic works through the NAT, so
  certbot's DNS-01 challenge (your DNS provider's API plugin) needs no inbound access at
  all and suits internal-only sites. HTTP-01 also works if your router forwards port 80
  to the Mac, because macvs already forwards 80 on to the guest. Certbot's renewal timer
  runs inside the guest unchanged.
- **Names you do not own** belong under a reserved TLD such as `.test`, `.internal`, or
  `.home.arpa`, with a private CA (for example `mkcert`) whose root the clients trust.
  Avoid `.local`; macOS reserves it for Bonjour.
- **The guest sees every client as `10.0.2.2`.** User-mode networking hides real client
  addresses, so access logs and IP-based rules inside the guest cannot tell clients apart.
  Giving the VM its own LAN address needs Apple's vmnet, which requires QEMU to run as
  root; it is not offered in this stage.
- **Only one VM can own 80 and 443.** Additional VMs get their own high ports
  (`--no-web --forward 8081:80`), or you put a reverse proxy in the first VM.

## How it works

```
 macvs create ──► cloud.debian.org ── SHA-512 verified ──► ~/.macvs/images/trixie/debian-13-generic-arm64.qcow2
                                                                     │  APFS clone + qemu-img resize
                                                                     ▼
 ~/.macvs/vms/<name>/            disk.qcow2   nvram.fd (UEFI vars)   seed.iso (cloud-init NoCloud, built by hdiutil)
                                      │            │                    │
                                      ▼            ▼                    ▼
 qemu-system-aarch64 -machine virt -accel hvf -cpu host  …  -netdev user,hostfwd=tcp:0.0.0.0:80-:80,hostfwd=…:443-:443,hostfwd=…:2222-:22
        │ virtio-balloon free-page-reporting  ──► freed guest pages returned to macOS
        │ serial ──► run/console.sock + logs/console.log
        │ QMP    ──► run/qmp.sock   (used by `stop` for a clean ACPI power-off)
        └ pid    ──► run/qemu.pid
 launchd ──► macvs run <name>  (foreground; SIGTERM becomes an ACPI power-off)
```

1. **Image.** `create` fetches `SHA512SUMS` from the Debian cloud-image site, downloads the
   current `generic` arm64 qcow2 for the release, verifies it, and caches it per release.
   Later VMs reuse the cache without touching the network; `macvs image pull --refresh`
   picks up a newer upstream build.
2. **Disk.** The verified image is cloned (instant on APFS, no backing-file dependency)
   and resized to `--disk`. Debian's cloud image grows its root filesystem on first boot.
3. **Firmware.** Each VM gets its own copy of the EDK2 UEFI variable store; the read-only
   firmware code comes from the QEMU installation.
4. **First boot.** A tiny ISO labelled `cidata` carries `user-data` and `meta-data`.
   cloud-init sets the hostname, creates the admin user with your SSH key and
   passwordless sudo, disables root and SSH password login, sets the timezone, and
   refreshes the apt index. Nothing else is installed.
5. **Supervision.** launchd runs `macvs run <name>`, which keeps QEMU in the foreground
   so launchd tracks the real process, restarts it only after a non-zero exit, and turns
   `SIGTERM` (shutdown, restart, bootout) into a clean guest power-off.

### Directory layout

```
~/.macvs/
├── app/                        the installed copy of this repository (bin, lib, share)
├── config                      optional overrides (see share/macvs/macvs.conf.example)
├── images/<release>/           cached base image, its .sha512, and SHA512SUMS
└── vms/<name>/
    ├── vm.conf                 the VM's settings (shell key=value; edit while stopped)
    ├── disk.qcow2  nvram.fd  [seed.iso]
    ├── cloud-init/user-data, meta-data      (created VMs only)
    ├── ssh/known_hosts [id_ed25519 if a key was generated]
    ├── run/qemu.pid, qmp.sock, console.sock
    └── logs/console.log, qemu.log, launchd.log
```

Set `MACVS_HOME` to relocate all of it. Keep it out of `~/Documents`, `~/Desktop`, and
`~/Downloads`: those folders are TCC-protected and launchd jobs may be denied access.

## Running as a service

Every created or imported VM gets a launchd job unless you pass `--no-daemon`.

- **system** (default): `/Library/LaunchDaemons`, loaded at boot before login. Needs
  sudo to install; QEMU runs as your user via `UserName`, so every file stays yours.
- **agent** (`--agent`): `~/Library/LaunchAgents`, loaded when you log in, no sudo.
- **autostart on** (default): `RunAtLoad` plus `KeepAlive` with `SuccessfulExit=false`.
  launchd starts the VM at load and restarts it only after a crash. `macvs stop` powers
  the guest off (exit 0), so it stays off until `macvs start` or the next boot/login.
- **autostart off**: the job stays installed but launchd only runs it when asked
  (`macvs start`). No boot-time start, no crash restart. Toggling it while the VM runs
  rewrites the plist for the next load; toggling it while stopped applies immediately.
- `macvs start` on a daemon-managed VM uses `launchctl kickstart`. `macvs status` shows
  launchd's view (`running`, `spawn scheduled`, …) and the autostart setting.
- `daemon install` refuses to run from a TCC-protected folder and rolls the job back if
  QEMU is not up within 15 seconds, so a broken job can never sit in a relaunch loop.

## Footprint

Measured on this project's reference Mac with a 2048 MiB Debian 13 VM:

| | Value |
|---|---|
| Idle CPU | about 0.5% of one core right after boot, 0.15% averaged over a month |
| Guest memory in use, idle | about 140 MB |
| Host memory after a 1 GiB burst in the guest, 30 s later | 869 MB with the balloon, 1035 MB without |
| Host memory of a 1 GiB VM idle for a month | 33 MB resident |

The balloon's free-page reporting hands memory back within seconds; macOS's own
compression takes care of the long tail. `discard=unmap` plus Debian's weekly `fstrim`
keep the qcow2 from growing past what the guest actually uses.

## Networking

QEMU user-mode networking (slirp) is used: no root, no kernel extensions, works on
any Wi-Fi or wired network. The guest reaches the internet through NAT and sees the
host at `10.0.2.2`. Everything else reaches the guest only through the forwarded ports.
Add forwards at creation (`--forward 8080:8080`) or later by editing `VM_FORWARDS` in
`vm.conf` while the VM is stopped. Forwards bind to `0.0.0.0` by default; use
`--bind 127.0.0.1` (or set `MACVS_DEFAULT_BIND`) to keep a VM reachable only from this Mac.

## Configuration

Global defaults live in `~/.macvs/config` (shell syntax; `share/macvs/macvs.conf.example`
lists every key). Per-VM settings are in `~/.macvs/vms/<name>/vm.conf`. Changing CPUs,
memory, forwards, cache mode, or the balloon takes effect at the next start. Changing the
user, key, timezone, or password of a created VM requires `macvs reseed <name>` and only
applies to modules cloud-init runs per instance. `VM_EXTRA_ARGS` appends raw QEMU
arguments if you need something the CLI does not expose.

## Migrating from a hand-built QEMU setup

If you already run a VM from a shell script plus a launchd plist, read
[docs/MIGRATING.md](docs/MIGRATING.md). The short version: do not combine `-daemonize`
with `KeepAlive` (launchd relaunches the script every ten seconds and the error log grows
forever), and use `macvs import` to adopt the existing disk.

## Troubleshooting

- `macvs doctor` checks the host and reports whether ports 80 and 443 are free.
  `macvs logs <name>` shows the guest's serial console; `--qemu` shows QEMU's own
  messages; `--launchd` the service log.
- **`host port 443 is already in use`.** Something on the Mac (another VM, Apache,
  a dev server) owns it. Pass `--no-web`, or free the port.
- **SSH never comes up.** Look at `macvs logs <name>`. For imports, check that the
  guest actually runs sshd on port 22 and that `--user`/`--ssh-key` match.
- **`Operation not permitted` in launchd.log.** The job points at a script inside a folder
  macOS privacy controls protect. Run `./install.sh`, then `macvs daemon install` again.
- **`Failed to get "write" lock`.** Another QEMU already has the disk open; `macvs status`
  shows the pid. Never start the same VM twice.
- **Guest ignores power-off.** `stop` waits `MACVS_STOP_TIMEOUT` (90 s) and then forces
  QEMU to quit; `--force` skips the wait.

## Roadmap

Later stages: provisioning profiles layered on the blank server (web stack, TLS with a
private CA), a vmnet option for VMs that need their own LAN address, snapshots, and
`macvs hosts` to manage the `/etc/hosts` entries for internal sites.

## Repository layout

```
bin/macvs                 CLI entry point (bash)
lib/macvs/common.sh       config, logging, vm.conf handling, port checks
lib/macvs/image.sh        Debian cloud image download and SHA-512 verification
lib/macvs/cloudinit.sh    user-data / meta-data and the cidata ISO (hdiutil)
lib/macvs/qemu.sh         QEMU arguments, start/stop, QMP, SSH, serial console
lib/macvs/launchd.sh      plist generation, install/uninstall, autostart, kickstart
lib/macvs/commands.sh     command implementations and dispatch
share/macvs/macvs.conf.example
docs/MIGRATING.md         adopting a hand-built QEMU VM
install.sh
```
