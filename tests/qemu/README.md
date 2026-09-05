# QEMU smoke test

This test performs a destructive install only inside a newly created qcow2
image. It boots the official Slackware64 15.0 installer, runs `owenslackinstall`
against a local package mirror, reboots from the resulting disk, logs in as
root, and verifies:

- the baseline x86_64 binary runs on QEMU's default CPU
- all 83 minimal-profile packages install successfully
- LILO reaches the Slackware login prompt
- the configured root password and hostname work
- core runtime, storage, network, firewall and udev commands start cleanly
- DHCP address, route and ping work
- configured DNS servers survive DHCP renewal
- `/dev/shm`, root, boot and swap mounts match the generated `fstab`

Requirements: Zig 0.16.0, QEMU, Expect, xorriso, Python 3 and `md5sum`.
KVM is used when available; otherwise the test falls back to TCG.

Run it with the official install DVD:

```sh
SLACKWARE_ISO=/path/to/slackware64-15.0-install-dvd.iso tests/qemu/run.sh
```

The ISO is verified against MD5
`f8418ef0ec2c0a205adf5dbc2f2a1971`. Selected Slackware packages are cached
under `~/.cache/owenslackinstall-qemu/mirror`; each run gets a separate directory
containing its disk and console logs. Set `owenslackinstall_QEMU_DIR` to use a
different cache location.
