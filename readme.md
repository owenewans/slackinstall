<div align="center">

# owenslackinstall

a minimal installer for slackware, written in zig. interactive TUI by
default, JSON config for scripted installs.

<a href="https://count.owenewans.org/owenewans/owenslackinstall?theme=moebooru-h&notitle"><img src="https://count.owenewans.org/owenewans/owenslackinstall?theme=moebooru-h&notitle" alt="repository views"></a>

`zig` `slackware` `installer` `sfdisk` `lilo` `unbound`

</div>

Slackware's stock `setup` installer works, but it is menu-heavy and has no
config-driven install mode. `owenslackinstall` is a single static binary for
Slackware 15.0, built separately for `x86_64` and `x86` (i686), that:

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

The `x86_64` build carries this same real-install, real-boot QEMU
verification. The `x86` (i686) build targets the plain (non-`slackware64`)
Slackware 15.0 package tree with its own independently-verified package
index (see [Profiles](#profiles)), and the cross-compiled binary is checked
under `qemu-i386` user-mode emulation, but has not been through the same
destructive install-and-boot QEMU test as `x86_64` - no bootable 32-bit
install DVD image was available to run it against. If you install on real
32-bit hardware, treat it as less battle-tested and keep a way to reboot
from other media until you've confirmed it boots. Legacy BIOS and LILO
only. Package checksums are not yet verified before `installpkg`; use a
trusted mirror. See [Limitations](#limitations).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/owenewans/owenslackinstall/master/install.sh | sh
```

or, from the self-hosted mirror:

```sh
curl -fsSL https://src.owenewans.org/owenslackinstall/-/install.sh?raw | sh
```

The official Slackware install DVD's live environment ships busybox `wget`,
not `curl`; from that shell, use:

```sh
wget -q -O - "https://src.owenewans.org/owenslackinstall/-/install.sh?raw" | sh
```

`install.sh` downloads the release binary from GitHub by default. If that
fails - some minimal TLS clients (e.g. BusyBox `wget`'s built-in TLS in a
bare Slackware live environment) can't complete a handshake with GitHub's
release CDN - it automatically retries once through a small live
pass-through proxy at `src.owenewans.org`, with no extra flags needed. The
proxy re-fetches the exact requested asset from GitHub on every request, so
it never serves anything stale. Set `owenslackinstall_DOWNLOAD_BASE` to skip
both and use your own source instead.

## Usage

```sh
# interactive: pick a disk, profile, DNS mode; confirms before touching anything
owenslackinstall install

# list the packages a profile would install
owenslackinstall profile server

# scripted: preview a full install plan, no changes made
owenslackinstall plan --config config.json

# scripted: execute the destructive install
owenslackinstall apply --config config.json -y
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

`package_mirror` is optional: it defaults to the `slackware64` tree on an
`x86_64` build and the `slackware` (32-bit) tree on an `x86` build, matching
that binary's package index. Only override it to point at a different
mirror host, not to switch architectures within the same binary.

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
`src/data/tagfiles/`, shared by both architectures (the same packages are
tagged `ADD`/`REC`/`OPT`/`SKP` on both trees for a given release). Each
build embeds its own frozen package index - `src/data/pkgindex.tsv` for
`x86_64` (the `slackware64` tree), `src/data/pkgindex-x86.tsv` for `x86`
(the plain `slackware` tree) - generated from that architecture's real
`PACKAGES.TXT`, since build numbers per package are not always identical
between the two trees.

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
zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSafe
```

The explicit target is important for a portable baseline CPU binary. A default
native build may use instructions available only on the build machine.
`builtin.target.cpu.arch` at comptime picks the matching package index and
default mirror (see [Profiles](#profiles)), so cross-compiling to `x86`
produces a binary for 32-bit Slackware, not a 64-bit one that happens to run
under compatibility mode.

Run the destructive end-to-end test only against its disposable qcow2 image:

```sh
SLACKWARE_ISO=/path/to/slackware64-15.0-install-dvd.iso tests/qemu/run.sh
```

See [`tests/qemu/README.md`](tests/qemu/README.md) for requirements and cache
details.

## Limitations

- Slackware 15.0 package trees only (`slackware64` and `slackware`)
- the `x86` (32-bit) build has not been through a destructive install-and-boot
  QEMU test, unlike `x86_64` - see [Status](#status)
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
