<div align="center">

# slackinstall

a minimal installer for slackware, written in zig. interactive TUI by
default, JSON config for scripted installs.

<a href="https://count.owenewans.org/owenewans/slackinstall?theme=moebooru-h&notitle"><img src="https://count.owenewans.org/owenewans/slackinstall?theme=moebooru-h&notitle" alt="repository views"></a>

`zig` `slackware` `installer` `sfdisk` `lilo` `unbound`

</div>

Slackware's stock `setup` installer works, but it is menu-heavy and has no
config-driven install mode. `slackinstall` is a single static binary for
Slackware64 15.0 that:

- offers `minimal`, `server` and `desktop` profiles derived from Slackware's
  native tagfiles and package tree
- provides an interactive installer that detects real disks and previews the
  complete plan before confirmation
- provides `plan` and `apply` commands driven by one JSON file for unattended
  installs
- partitions, formats, mounts, downloads packages, configures the target and
  installs LILO instead of delegating to a dry-run backend
- writes native Slackware configuration including `fstab`,
  `/etc/rc.d/rc.inet1.conf`, `/etc/HOSTNAME`, `/etc/hosts`, DNS policy and
  `/etc/lilo.conf`
- never erases a disk without interactive confirmation or explicit
  `-y`/`--confirm`

## Status

`install` and `apply -y` are real, privileged and destructive. The QEMU smoke
test starts from a blank virtio disk and the official Slackware64 15.0 DVD,
installs the 83-package minimal profile, boots it through LILO, logs in with
the configured root password, and verifies runtime libraries, DHCP, ping,
DNS persistence, hostname, `fstab`, swap and `/dev/shm`.

Current scope is x86_64, legacy BIOS and LILO. Package checksums are not yet
verified before `installpkg`; use a trusted mirror. See [Limitations](#limitations).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/owenewans/slackinstall/master/install.sh | sh
```

or, from the self-hosted mirror:

```sh
curl -fsSL https://src.owenewans.org/slackinstall/-/install.sh?raw | sh
```

The official Slackware install DVD's live environment ships busybox `wget`,
not `curl`; from that shell, use:

```sh
wget -q -O - "https://src.owenewans.org/slackinstall/-/install.sh?raw" | sh
```

## Usage

```sh
# interactive: pick a disk, profile, DNS mode; confirms before touching anything
slackinstall install

# list the packages a profile would install
slackinstall profile server

# scripted: preview a full install plan, no changes made
slackinstall plan --config config.json

# scripted: execute the destructive install
slackinstall apply --config config.json -y
```

`config.json`:

```json
{
  "disk": "/dev/sda",
  "hostname": "web-01",
  "profile": "minimal",
  "dns_mode": "plain",
  "dns_servers": ["9.9.9.9", "1.1.1.1"],
  "package_mirror": "http://slackware.osuosl.org/slackware64-15.0/slackware64",
  "swap_mb": 4096,
  "root_password": "replace-this",
  "network_interface": "eth0"
}
```

`network_interface` selects which NIC DHCP runs on, both during install and
in the target's `/etc/rc.d/rc.inet1.conf`. `install` detects real interfaces
from `/sys/class/net` and prompts for one instead of assuming `eth0`; `apply`
defaults to `eth0` if omitted.

`root_password` is optional. It is hashed with SHA-512 in the live environment
and plaintext is not written to the target, but the JSON file itself still
contains the secret and should be protected. If omitted, the target root
account remains locked.

## Profiles

Profiles are computed from Slackware 15.0 tagfiles embedded under
`src/data/tagfiles/`. The package index is frozen to the Slackware64 15.0
package tree.

| profile | selection |
|---------|-----------|
| minimal | `a:ADD` plus an explicit boot, storage and network runtime closure, 83 packages |
| server | `ADD` and `REC` from `a`, `ap`, `d`, `l`, `n`, `t`, `tcl`, without X11 |
| desktop | `ADD` and `REC` from every series, including X11, Xfce and KDE |

## Development

```sh
zig build test
zig build run -- plan --config config.json
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
```

The explicit target is important for a portable baseline CPU binary. A default
native build may use instructions available only on the build machine.

Run the destructive end-to-end test only against its disposable qcow2 image:

```sh
SLACKWARE_ISO=/path/to/slackware64-15.0-install-dvd.iso tests/qemu/run.sh
```

See [`tests/qemu/README.md`](tests/qemu/README.md) for requirements and cache
details.

## Limitations

- Slackware64 15.0 package tree only
- legacy BIOS and LILO only, no UEFI bootloader
- DHCP only; static addressing is not implemented (interface selection is,
  see `network_interface` above)
- downloaded Slackware packages are not checksum-verified yet
- DoT writes an unbound forward-zone and DoH writes a local-stub template, but
  the required resolver is not auto-installed because it is absent from the
  official Slackware 15.0 repository
- the QEMU smoke test is local and not run in hosted CI because it requires the
  Slackware install DVD

## License

GPLv3, see [`LICENSE`](LICENSE).
