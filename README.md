# macVS

Deployable Debian virtual servers on Apple Silicon Macs.

One command creates a blank **Debian 13 (trixie)** server that runs under QEMU with
Apple's Hypervisor.framework, is configured unattended by cloud-init on first boot,
and can be registered with launchd so it comes up whenever the Mac does.

```
$ macvs create web --start
==> creating 25G disk from debian-13-generic-arm64.qcow2
==> building cloud-init seed (user 'admin', hostname 'web')
 ok  created web in /Users/you/.macvs/vms/web
==> starting web (2 vCPU, 2048 MiB, ssh 127.0.0.1:2222)
 ok  SSH is up after 6s
 ok  cloud-init: done

Connect:  macvs ssh web
```

This is stage one of the project: it produces a clean Debian 13 server and nothing
else. Web-tool development features are intentionally out of scope for now.

## Requirements

- An Apple Silicon Mac (arm64) with virtualization enabled (`sysctl kern.hv_support` is `1`).
- [Homebrew](https://brew.sh) and QEMU: `brew install qemu` (tested with QEMU 11.1 on macOS 26).
- Nothing else. Image download and verification, the cloud-init seed, SSH, and the
  service integration use only tools that ship with macOS (`curl`, `shasum`, `hdiutil`,
  `ssh`, `nc`, `launchctl`). The CLI is plain bash 3.2, the version macOS ships.
- Optional: `brew install openssl@3` if you want `--password` (a console password for the admin user).

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
macvs create web --start        # download image (once), create, boot, wait for SSH
macvs ssh web                   # log in as 'admin' (passwordless sudo)
macvs stop web                  # clean ACPI power-off
macvs daemon install web        # run it as a system service that starts at boot (sudo)
macvs status web
macvs destroy web --yes
```

Options for `create` (defaults in parentheses, all overridable in `~/.macvs/config`):

| Option | Meaning |
|---|---|
| `--cpus N` | vCPUs (2) |
| `--memory MiB` | RAM (2048) |
| `--disk SIZE` | virtual disk, grown on first boot (25G) |
| `--ssh-port PORT` | host port forwarded to guest 22 (first free port from 2222) |
| `--forward H:G` | extra TCP forward host→guest; repeatable, e.g. `--forward 8080:80` |
| `--bind ADDR` | address forwards bind to (127.0.0.1; use `0.0.0.0` for LAN access) |
| `--user NAME` | admin user created in the guest (admin) |
| `--ssh-key FILE.pub` | key to authorise (your `~/.ssh/id_ed25519.pub`, else a new per-VM key) |
| `--password` | prompt for a serial-console password; SSH stays key-only |
| `--timezone TZ` | guest timezone (this Mac's) |
| `--release NAME` | Debian codename (trixie = 13) |
| `--variant NAME` | cloud image variant: `generic` or `genericcloud` (generic) |
| `--start` | boot and wait for SSH and cloud-init |
| `--daemon [system\|agent]` | also register with launchd and start it |

## Commands

| Command | What it does |
|---|---|
| `macvs create <name> [opts]` | Create a VM from the cached, checksum-verified Debian image |
| `macvs start <name>` | Boot it (through launchd if a daemon is installed, otherwise detached) |
| `macvs stop <name> [--force]` | ACPI power-off via QMP; escalates to quit/kill after the timeout |
| `macvs restart <name>` | Stop then start |
| `macvs destroy <name> [--yes]` | Stop, remove the launchd job, delete `~/.macvs/vms/<name>` |
| `macvs list` / `macvs status <name>` | State, pid, uptime, ports, launchd status |
| `macvs ssh <name> [cmd]` | SSH with the right port, key and a per-VM known_hosts file |
| `macvs ssh-config <name>` | Print a `Host` block for `~/.ssh/config` |
| `macvs console <name>` | Attach to the serial console (press Enter for a prompt, `Ctrl-]` to detach) |
| `macvs logs <name> [-f] [--console\|--qemu\|--launchd]` | Tail the console, QEMU, or launchd log |
| `macvs wait <name>` | Block until SSH answers and cloud-init reports done |
| `macvs reseed <name>` | Rebuild the cloud-init seed after editing `vm.conf` (VM stopped) |
| `macvs daemon install <name> [--system\|--agent]` | Register with launchd (system needs sudo) |
| `macvs daemon uninstall\|status\|plist <name>` | Manage or inspect the launchd job |
| `macvs image pull [--refresh]` / `list` / `rm <release>` | Manage cached base images |
| `macvs doctor` | Check the Mac for everything macvs needs |
| `macvs run <name>` | Run QEMU in the foreground (this is what launchd executes) |

## How it works

```
 macvs create ──► cloud.debian.org ── SHA-512 verified ──► ~/.macvs/images/trixie/debian-13-generic-arm64.qcow2
                                                                     │  APFS clone + qemu-img resize
                                                                     ▼
 ~/.macvs/vms/<name>/            disk.qcow2   nvram.fd (UEFI vars)   seed.iso (cloud-init NoCloud, built by hdiutil)
                                      │            │                    │
                                      ▼            ▼                    ▼
 qemu-system-aarch64 -machine virt -accel hvf -cpu host  …  -netdev user,hostfwd=tcp:127.0.0.1:2222-:22
        │ serial ──► run/console.sock + logs/console.log
        │ QMP    ──► run/qmp.sock   (used by `stop` for a clean ACPI power-off)
        └ pid    ──► run/qemu.pid
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
   refreshes the apt index. Nothing else is installed: the server is blank.
5. **Access.** User-mode networking with port forwards. SSH on `127.0.0.1:<port>`;
   `macvs ssh` handles the port, identity, and a per-VM `known_hosts` so recreating a
   VM never trips host-key warnings.

### Directory layout

```
~/.macvs/
├── app/                        the installed copy of this repository (bin, lib, share)
├── config                      optional overrides (see share/macvs/macvs.conf.example)
├── images/<release>/           cached base image, its .sha512, and SHA512SUMS
└── vms/<name>/
    ├── vm.conf                 the VM's settings (shell key=value; edit while stopped)
    ├── disk.qcow2  nvram.fd  seed.iso
    ├── cloud-init/user-data, meta-data
    ├── ssh/known_hosts [id_ed25519 if a key was generated]
    ├── run/qemu.pid, qmp.sock, console.sock
    └── logs/console.log, qemu.log, launchd.log
```

Set `MACVS_HOME` to relocate all of it. Keep it out of `~/Documents`, `~/Desktop`, and
`~/Downloads`: those folders are TCC-protected and launchd jobs may be denied access.

## Running as a service

```bash
macvs daemon install web             # /Library/LaunchDaemons, starts at boot (sudo)
macvs daemon install web --agent     # ~/Library/LaunchAgents, starts at login (no sudo)
```

- The job runs `macvs run <name>`, which keeps QEMU in the **foreground** so launchd
  tracks the real process. When launchd sends `SIGTERM` (shutdown, restart, `bootout`),
  the wrapper turns it into an ACPI power-off and waits for the guest to halt cleanly.
- With a system daemon QEMU still runs **as your user** (`UserName` in the plist), so
  every file stays yours. Forwarding ports below 1024 would need root and is not
  supported in this stage.
- `KeepAlive` is `SuccessfulExit=false`: launchd restarts QEMU only if it exits with an
  error. `macvs stop` powers the guest off (exit 0), so it stays off until `macvs start`
  or the next boot/login. `macvs start` on a daemon-managed VM uses `launchctl kickstart`.
- `macvs status` shows launchd's view of the job (`running`, `spawn scheduled`, …).
- The job runs the installed copy in `~/.macvs/app`, never the clone, so `daemon install`
  refuses to run from a TCC-protected folder and rolls the job back if QEMU does not come
  up within 15 seconds. Both keep a broken job from looping under `KeepAlive`.

## Networking

QEMU user-mode networking (slirp) is used: no root, no kernel extensions, works on
any Wi-Fi or wired network. Consequences:

- The guest reaches the internet through NAT and sees the host at `10.0.2.2`.
- Anything else reaches the guest only through the forwarded ports. Add forwards at
  creation (`--forward 8080:80`) or later by editing `VM_FORWARDS` in `vm.conf` while the
  VM is stopped.
- Forwards bind to `127.0.0.1` by default. Use `--bind 0.0.0.0` (or
  `MACVS_DEFAULT_BIND=0.0.0.0` in the config) to reach the VM from other machines on your LAN.

## Configuration

Global defaults live in `~/.macvs/config` (shell syntax; `share/macvs/macvs.conf.example`
lists every key). Per-VM settings are in `~/.macvs/vms/<name>/vm.conf`. Changing CPUs,
memory, forwards, or cache mode takes effect at the next start. Changing the user, key,
timezone, or password requires `macvs reseed <name>` and only applies to modules
cloud-init runs per instance.

`VM_EXTRA_ARGS` in `vm.conf` appends raw QEMU arguments if you need something the CLI
does not expose.

## Migrating from a hand-built QEMU setup

If you already run a VM from a shell script plus a launchd plist, note two things this
project does differently:

- **Do not combine `-daemonize` with `KeepAlive`.** When the script exits after QEMU
  daemonizes, launchd believes the job died and relaunches it every 10 seconds; each
  relaunch fails to lock the disk image and appends to the error log forever. `macvs run`
  keeps QEMU in the foreground so launchd tracks it correctly.
- `SIGTERM` at shutdown becomes a clean guest power-off instead of an abrupt kill.

Importing an existing qcow2 is not supported in this stage; create a new server and
move your data over.

## Troubleshooting

- `macvs doctor` checks the host. `macvs logs <name>` shows the guest's serial console;
  `--qemu` shows QEMU's own messages; `--launchd` the service log.
- **SSH never comes up.** Look at `macvs logs <name>`. A missing `cidata` seed or a bad
  public key shows up in cloud-init's output there.
- **`Failed to get "write" lock`.** Another QEMU already has the disk open; `macvs status`
  shows the pid. Never start the same VM twice.
- **`Operation not permitted` in launchd.log.** The job points at a script inside a folder
  macOS privacy controls protect. Run `./install.sh`, then `macvs daemon install` again
  using the installed `macvs`.
- **Port already in use.** `create` refuses ports that are listening or assigned to another
  macvs VM. Pick another with `--ssh-port`.
- **Guest ignores power-off.** `stop` waits `MACVS_STOP_TIMEOUT` (90 s) and then forces
  QEMU to quit; `--force` skips the wait.

## Roadmap

Stage two adds what the web-tool development environment needs: ports 80/443,
LAN-reachable addresses, provisioning profiles layered on top of the blank server,
importing an existing disk image, and snapshots.

## Repository layout

```
bin/macvs                 CLI entry point (bash)
lib/macvs/common.sh       config, logging, vm.conf handling, port checks
lib/macvs/image.sh        Debian cloud image download and SHA-512 verification
lib/macvs/cloudinit.sh    user-data / meta-data and the cidata ISO (hdiutil)
lib/macvs/qemu.sh         QEMU arguments, start/stop, QMP, SSH, serial console
lib/macvs/launchd.sh      plist generation, install/uninstall, kickstart
lib/macvs/commands.sh     command implementations and dispatch
share/macvs/macvs.conf.example
install.sh
```
