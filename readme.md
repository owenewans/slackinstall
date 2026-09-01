<div align="center">

# slackinstall

a minimal, non-interactive-friendly installer for slackware, written in zig.

<a href="https://count.owenewans.org/owenewans/slackinstall?theme=moebooru-h&notitle"><img src="https://count.owenewans.org/owenewans/slackinstall?theme=moebooru-h&notitle" alt="repository views"></a>

`zig` `slackware` `installer` `sfdisk` `lilo` `unbound`

</div>

Slackware's stock `setup` installer works, but it is menu-heavy, has no
config-driven install mode, and offers no equivalent to
[archinstall](https://github.com/archlinux/archinstall)'s minimal/server/desktop
profiles. `slackinstall` is a single static binary that:

- builds package lists directly from slackware 15.0's own tagfiles (no
  re-invented package metadata), collapsed into three profiles: `minimal`,
  `server`, `desktop`
- takes a single JSON config file and runs non-interactively (`plan` to
  preview, `apply` to execute)
- never touches a disk without an explicit `--yes-i-am-sure` flag
- generates native slackware config: `/etc/rc.d/rc.inet1.conf`, `/etc/HOSTNAME`,
  `/etc/lilo.conf`, and an unbound forward-zone stanza for plain, DoT or DoH
  resolution

## Status

Early. Package profile generation, config validation, disk-plan generation
and config-file rendering (network, DNS, LILO) are implemented and unit
tested. Actual privileged execution (`apply` without dry-run: partitioning,
`installpkg`, chroot, `lilo`) is not wired up yet — `apply` currently always
runs its disk steps in dry-run mode. See [Roadmap](#roadmap).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/owenewans/slackinstall/master/install.sh | sh
```

## Usage

```sh
# list the packages a profile would install
slackinstall profile server

# preview a full install plan, no changes made
slackinstall plan --config config.json

# execute (currently still dry-run internally, see Status)
slackinstall apply --config config.json --yes-i-am-sure
```

`config.json`:

```json
{
  "disk": "/dev/sda",
  "hostname": "web-01",
  "profile": "server",
  "dns_mode": "dot",
  "dns_servers": ["9.9.9.9", "1.1.1.1"],
  "swap_mb": 4096
}
```

## Profiles

Profiles are computed at compile time from slackware 15.0's actual `tagfile`
per disk series (`a`, `ap`, `d`, `l`, `n`, `x`, `xap`, `xfce`, `kde`, ...),
embedded under `src/data/tagfiles/`.

| profile   | series included                          | tags        |
|-----------|-------------------------------------------|-------------|
| minimal   | `a`, `n`                                   | `ADD`       |
| server    | `a`, `ap`, `d`, `l`, `n`, `t`, `tcl`        | `ADD`+`REC` |
| desktop   | every series (adds `x`, `xap`, `xfce`, `kde`) | `ADD`+`REC` |

## Development

```sh
zig build test
zig build run -- plan --config config.json
```

Cross-compiling for both slackware architectures:

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall
```

## Roadmap

Manually verified against `docker.io/vbatts/slackware` (real Slackware 15.0
userspace, no loop-device access available in this sandbox): the exact
`sfdisk` script, `mkfs.ext4`/`mkswap` invocations and an `installpkg` run
against a real package from the `a` series all succeed unmodified. What is
not wired into the CLI yet:

- [ ] privileged `apply`: real `sfdisk`/`mkfs`/`mkswap` execution (currently
      always dry-run; command sequences themselves are verified, see above)
- [ ] package fetch + `installpkg` inside a target root, driven by `Profile.packageList`
- [ ] chroot setup and `lilo` install
- [ ] podman-based end-to-end test harness wired into CI (requires
      loop-device/`--privileged` access; the manual verification above used a
      real root filesystem but partitioned a plain file, not a block device)
- [ ] CI matrix building x86 and x86_64 release binaries

## License

GPLv3, see [`LICENSE`](LICENSE).
