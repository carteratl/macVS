# Migrating a hand-built QEMU VM to macvs

This applies to a VM you start from your own shell script through a launchd plist,
such as the `ponder.carter.network` setup this project grew out of. The concrete
commands below use that VM; substitute your own names and paths.

## Why migrate

A common hand-built plist has `KeepAlive` set to true while the script starts QEMU
with `-daemonize`. The script exits as soon as QEMU forks, launchd treats that as a
crash, and it relaunches the script every ten seconds forever. Each relaunch fails to
lock the disk image and appends two lines to the error log. The VM keeps running, but
the log grows without bound and launchd never actually supervises QEMU: a crash would
not be restarted and shutdown kills it without a clean guest power-off.

Under macvs the same VM runs in the foreground under launchd, restarts only after a
crash, powers off cleanly on shutdown, and returns idle memory to macOS.

## What you need

- macvs installed (`./install.sh`) and `macvs doctor` green.
- The guest's login user and how you authenticate (a key file, or a password).
- A moment of downtime: the guest is powered off once and booted again under macvs.

## Steps

**1. Stop the old launchd job.** This ends the relaunch loop. It does not stop the QEMU
that is already running, because that process detached from launchd long ago.

```bash
sudo launchctl bootout system/ponder.carter.network
sudo rm /Library/LaunchDaemons/vm.ponder.carter.network.plist
```

**2. Power the guest off from inside.** The old QEMU has no monitor socket, so the
clean way is a guest-initiated shutdown.

```bash
ssh -t -p 2222 josh@localhost sudo poweroff
```

Wait until the QEMU process is gone (repeat until it prints nothing, usually under a minute):

```bash
pgrep -fl ponder.carter.network
```

If it will not exit, `sudo kill <pid>` stops it the hard way; ext4 recovers, but prefer the clean route.

**3. Import.** The disk and UEFI variable store are cloned into `~/.macvs/vms/<name>`
(instant on APFS; the originals stay put as a fallback). sudo prompts once to install
the boot-time LaunchDaemon. The default web ports 80 and 443 and SSH on 2222 are
forwarded on the Mac's loopback only (add `--bind 0.0.0.0` if other machines must reach
them), and the VM boots with 2 vCPUs and 2048 MiB with the memory balloon.

```bash
macvs import ponder.carter.network \
  --disk  ~/.qemu/qcow2/ponder.carter.network.qcow2 \
  --nvram ~/.qemu/nvram/ponder.carter.network.edk2-aarch64-vars.fd \
  --user  josh \
  --ssh-port 2222
```

Add `--cache writethrough` if you want to keep the old script's slower but crash-safer
disk mode, and `--forward` for any extra ports the old script forwarded.

**4. Verify.**

```bash
macvs status ponder.carter.network
ssh -p 2222 josh@localhost
curl -k https://localhost/
macvs logs ponder.carter.network
```

**5. Optional: key-based login** so `macvs ssh` works without a password prompt.

```bash
ssh-copy-id -p 2222 -i ~/.ssh/id_carter_servers_joshcarter_ed25519.pub josh@localhost
```

Then set `VM_SSH_IDENTITY='/Users/joshcarter/.ssh/id_carter_servers_joshcarter_ed25519'`
in `~/.macvs/vms/ponder.carter.network/vm.conf`.

**6. Clean up** once you are satisfied.

```bash
sudo rm /var/log/ponder.carter.network.err /var/log/ponder.carter.network.out
```

Keep `~/.qemu` as a cold backup for a while, then delete it. Do not boot the old disk
again: everything that happens after the import lives only in the macvs clone.

## Rolling back

`macvs destroy ponder.carter.network --yes`, then reinstall the old plist from the copy in
`~/.qemu/plist/` with `sudo launchctl bootstrap system /Library/LaunchDaemons/<plist>`.
Changes made while running under macvs are lost, because the old disk was never touched.
