// orchestrates a real install: partition, format, mount, fetch + install
// packages, write config, install the bootloader. every side-effecting step
// goes through `disk.Executor` so dry-run/live behavior stays in one place
// and every command actually run is also printed as it happens.
const std = @import("std");
const config = @import("config.zig");
const disk = @import("disk.zig");
const net = @import("net.zig");
const dns = @import("dns.zig");
const boot = @import("boot.zig");
const pkgindex = @import("pkg/index.zig");

pub const target_root = "/mnt/slackinstall";

pub const Progress = struct {
    out: *std.Io.Writer,

    fn step(self: Progress, comptime fmt: []const u8, args: anytype) void {
        self.out.print("==> " ++ fmt ++ "\n", args) catch {};
        self.out.flush() catch {};
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, cfg: config.Config) !void {
    // every allocation made while actually running an install is scratch:
    // mount paths, argv copies, download urls. an arena means the many
    // small allocations below don't need individual `defer free`s and
    // nothing outlives this call.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const progress: Progress = .{ .out = out };
    const executor: disk.Executor = .{ .allocator = allocator, .io = io, .dry_run = false };

    const layout: disk.Layout = .{ .disk = cfg.disk, .swap_mb = cfg.swap_mb };
    const boot_part = try layout.bootPartition(allocator);
    const swap_part = try layout.swapPartition(allocator);
    const root_part = try layout.rootPartition(allocator);

    try ensureNetwork(io, progress, executor);

    progress.step("partitioning {s}", .{cfg.disk});
    const disk_steps = try disk.buildSteps(allocator, layout);
    // disk_steps[0] is sfdisk; [1..] are the mkfs/mkswap steps that need the
    // new partition device nodes to exist. udev creates those nodes
    // asynchronously after sfdisk's own BLKRRPART ioctl, so running the
    // format steps immediately after sfdisk is a race: it briefly worked in
    // manual testing but failed intermittently ("file does not exist") once
    // this ran for real against a virtio disk. wait for the nodes instead
    // of assuming a fixed delay is enough.
    try executor.run(disk_steps[0]);
    executor.run(.{ .argv = &.{ "udevadm", "settle", "--timeout=10" }, .description = "wait for udev to settle" }) catch {};
    try waitForPath(io, progress, boot_part);
    try waitForPath(io, progress, swap_part);
    try waitForPath(io, progress, root_part);
    for (disk_steps[1..]) |s| try executor.run(s);

    progress.step("mounting target filesystem", .{});
    try executor.run(.{ .argv = &.{ "mkdir", "-p", target_root }, .description = "create mount point" });
    try executor.run(.{ .argv = &.{ "mount", root_part, target_root }, .description = "mount root partition" });
    var root_mounted = true;
    defer if (root_mounted) executor.run(.{ .argv = &.{ "umount", target_root }, .description = "unmount root partition" }) catch {};

    const target_boot = try std.fmt.allocPrint(allocator, "{s}/boot", .{target_root});
    try executor.run(.{ .argv = &.{ "mkdir", "-p", target_boot }, .description = "create /boot mount point" });
    try executor.run(.{ .argv = &.{ "mount", boot_part, target_boot }, .description = "mount boot partition" });
    var boot_mounted = true;
    defer if (boot_mounted) executor.run(.{ .argv = &.{ "umount", target_boot }, .description = "unmount boot partition" }) catch {};

    try executor.run(.{ .argv = &.{ "swapon", swap_part }, .description = "enable swap" });
    var swap_enabled = true;
    defer if (swap_enabled) executor.run(.{ .argv = &.{ "swapoff", swap_part }, .description = "disable swap" }) catch {};

    try installPackages(allocator, io, progress, cfg);
    progress.step("updating target shared-library cache", .{});
    try executor.run(.{ .argv = &.{ "chroot", target_root, "/sbin/ldconfig" }, .description = "update target linker cache" });
    try writeTargetConfig(allocator, io, progress, cfg);
    try applyRootPassword(progress, executor, cfg);
    try enableSerialConsole(allocator, io, progress);
    try installBootloader(allocator, io, progress, executor, cfg, root_part);

    progress.step("unmounting target filesystem", .{});
    try executor.run(.{ .argv = &.{ "swapoff", swap_part }, .description = "disable swap" });
    swap_enabled = false;
    try executor.run(.{ .argv = &.{ "umount", target_boot }, .description = "unmount boot partition" });
    boot_mounted = false;
    try executor.run(.{ .argv = &.{ "umount", target_root }, .description = "unmount root partition" });
    root_mounted = false;

    progress.step("install complete: reboot into {s}", .{cfg.hostname});
}

/// Sets root's password by hashing it with busybox's `mkpasswd` and writing
/// the result directly into the target's /etc/shadow.
///
/// Two things were tried first and rejected based on what actually ran in
/// slackware's live install environment, not assumptions:
/// - `chroot <target> chpasswd`: fails with "pam_chauthtok() failed: Module
///   is unknown" - the shadow package's chpasswd is PAM-aware, but
///   slackware doesn't ship PAM by default, so the chroot has no usable
///   PAM stack.
/// - `openssl passwd -6`: openssl is not present in the live install
///   environment at all (it's part of the target's optional package set,
///   not the installer's own initrd).
///
/// `busybox mkpasswd` is always present (busybox itself is the install
/// environment's shell), needs no chroot, and needs no optional package.
/// The password is piped in on stdin, never passed as an argv element, so
/// it never appears in `ps` output.
fn applyRootPassword(progress: Progress, executor: disk.Executor, cfg: config.Config) !void {
    const plaintext = cfg.root_password orelse {
        progress.step("no root password set: root login will stay locked until one is set", .{});
        return;
    };
    progress.step("setting root password", .{});

    const script =
        \\set -e
        \\IFS= read -r password
        \\hash=$(printf '%s' "$password" | busybox mkpasswd -m sha512)
        \\sed -i "s#^root:[^:]*:#root:$hash:#"
    ++ " " ++ target_root ++ "/etc/shadow\n";

    const stdin_data = try std.fmt.allocPrint(executor.allocator, "{s}\n", .{plaintext});
    try executor.run(.{
        .argv = &.{ "sh", "-c", script },
        .description = "set root password",
        .stdin_data = stdin_data,
    });
}

/// busybox's udhcpc reports a lease over stdout but does not itself apply
/// any interface/route/resolv.conf configuration - that's left to a hook
/// script the caller must provide, and slackware's live install environment
/// ships none by default. without this, "network is unreachable" even
/// after "lease obtained". this writes a minimal hook and runs udhcpc once.
const udhcpc_hook_path = "/tmp/slackinstall-udhcpc.sh";
const udhcpc_hook_script =
    \\#!/bin/sh
    \\case "$1" in
    \\  bound|renew)
    \\    ip addr flush dev "$interface" 2>/dev/null
    \\    ip addr add "$ip/${subnet:-255.255.255.0}" dev "$interface"
    \\    ip link set "$interface" up
    \\    if [ -n "$router" ]; then
    \\      ip route replace default via "${router%% *}" dev "$interface"
    \\    fi
    \\    if [ -n "$dns" ]; then
    \\      : > /etc/resolv.conf
    \\      for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
    \\    fi
    \\    ;;
    \\esac
    \\
;

/// Polls for a device node to appear, up to ~5 seconds. udev creates
/// partition device nodes asynchronously after the kernel re-reads a
/// partition table, so callers must not assume `/dev/sdaN` exists the
/// instant `sfdisk` returns.
fn waitForPath(io: std.Io, progress: Progress, path: []const u8) !void {
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| {
            progress.step("{s} appeared after {d}ms", .{ path, attempt * 200 });
            return;
        } else |_| {
            std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
        }
    }
    return error.PartitionNodeNeverAppeared;
}

fn ensureNetwork(io: std.Io, progress: Progress, executor: disk.Executor) !void {
    progress.step("configuring network (dhcp on eth0)", .{});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = udhcpc_hook_path, .data = udhcpc_hook_script });
    try executor.run(.{ .argv = &.{ "chmod", "+x", udhcpc_hook_path }, .description = "make dhcp hook executable" });

    executor.run(.{
        .argv = &.{ "udhcpc", "-i", "eth0", "-s", udhcpc_hook_path, "-n", "-q" },
        .description = "obtain dhcp lease and configure eth0",
    }) catch |e| {
        // not fatal here: a static/pre-configured network, or a machine
        // with no eth0 at all (e.g. wifi-only), should still be able to
        // proceed if the caller already has working connectivity.
        progress.step("dhcp configuration failed ({t}), continuing with existing network state", .{e});
    };
}

fn installPackages(allocator: std.mem.Allocator, io: std.Io, progress: Progress, cfg: config.Config) !void {
    const executor: disk.Executor = .{ .allocator = allocator, .io = io, .dry_run = false };

    const names = try cfg.profile.packageList(allocator);
    const entries = try pkgindex.parse(allocator);

    const cache_dir = "/var/cache/slackinstall/packages";
    try executor.run(.{ .argv = &.{ "mkdir", "-p", cache_dir }, .description = "create package cache" });

    progress.step("installing {d} packages", .{names.len});
    for (names, 0..) |name, i| {
        const entry = pkgindex.find(entries, name) orelse {
            progress.step("cannot install {s}: not found in package index", .{name});
            return error.PackageNotFound;
        };
        const url = try pkgindex.packageUrl(allocator, cfg.package_mirror, entry);

        const basename = std.fs.path.basename(entry.path);
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, basename });

        progress.step("[{d}/{d}] {s}", .{ i + 1, names.len, name });
        // slackware's installer environment ships wget, not curl.
        try executor.run(.{
            .argv = &.{ "wget", "-q", "-T", "30", "-t", "3", "-O", dest, url },
            .description = "download package",
        });
        try executor.run(.{
            .argv = &.{ "installpkg", "--root", target_root, dest },
            .description = "install package",
        });
        try executor.run(.{
            .argv = &.{ "rm", "-f", dest },
            .description = "remove downloaded package",
        });
    }
}

fn writeTargetConfig(allocator: std.mem.Allocator, io: std.Io, progress: Progress, cfg: config.Config) !void {
    progress.step("writing target configuration", .{});

    const hostname_content = try net.renderHostname(allocator, cfg.hostname);
    try writeTargetFile(io, "/etc/HOSTNAME", hostname_content);

    const hosts_content = try net.renderHosts(allocator, cfg.hostname);
    try writeTargetFile(io, "/etc/hosts", hosts_content);

    const rc_inet1 = try net.renderRcInet1Conf(allocator, .{ .dhcp = .{ .interface = "eth0" } });
    try writeTargetFile(io, "/etc/rc.d/rc.inet1.conf", rc_inet1);
    try writeTargetFile(io, "/etc/dhcpcd.conf", net.renderDhcpcdConf());

    try writeTargetFile(io, "/etc/fstab", renderFstab());

    switch (cfg.dns_mode) {
        .plain => {
            const resolv = try dns.renderResolvConf(allocator, cfg.dns_servers);
            try writeTargetFile(io, "/etc/resolv.conf", resolv);
        },
        .dot, .doh => {
            // unbound is not part of the official slackware 15.0 repository
            // tree, so it is never auto-installed. this stanza is written as
            // a best-effort starting point for whoever installs unbound
            // (e.g. from SlackBuilds) after first boot; until then, fall
            // back to plain resolution so the system has working DNS.
            const forward = try dns.renderUnboundForward(allocator, cfg.dns_mode, cfg.dns_servers);
            try writeTargetFile(io, "/etc/unbound/conf.d/slackinstall-forward.conf", forward);

            const resolv = try dns.renderResolvConf(allocator, cfg.dns_servers);
            try writeTargetFile(io, "/etc/resolv.conf", resolv);
        },
    }
}

fn renderFstab() []const u8 {
    return
    \\LABEL=root  /      ext4  defaults  1  1
    \\LABEL=boot  /boot  ext4  defaults  1  2
    \\LABEL=swap  none   swap  sw        0  0
    \\proc        /proc  proc  defaults  0  0
    \\tmpfs       /dev/shm tmpfs defaults 0  0
    \\
    ;
}

/// Enables a login prompt on ttyS0, matching the `console=ttyS0` kernel
/// param set in lilo.conf. /etc/inittab ships the line commented out
/// (`#s1:12345:respawn:/sbin/agetty -L ttyS0 9600 vt100`); this appends an
/// active entry rather than trying to uncomment the template, since the
/// exact wording of that line isn't a stable contract to depend on.
fn enableSerialConsole(allocator: std.mem.Allocator, io: std.Io, progress: Progress) !void {
    progress.step("enabling serial console on ttyS0", .{});

    const inittab_path = target_root ++ "/etc/inittab";
    const existing = std.Io.Dir.cwd().readFileAlloc(io, inittab_path, allocator, .limited(1 << 20)) catch |e| {
        progress.step("could not read {s} ({t}), skipping serial console setup", .{ inittab_path, e });
        return;
    };

    const updated = try std.fmt.allocPrint(allocator,
        \\{s}
        \\s1:12345:respawn:/sbin/agetty -L 115200 ttyS0 vt100
        \\
    , .{existing});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = inittab_path, .data = updated });
}

fn writeTargetFile(io: std.Io, sub_path: []const u8, content: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ target_root, sub_path });

    const dir_path = std.fs.path.dirname(full_path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = content });
}

fn installBootloader(
    allocator: std.mem.Allocator,
    io: std.Io,
    progress: Progress,
    executor: disk.Executor,
    cfg: config.Config,
    root_part: []const u8,
) !void {
    progress.step("installing bootloader", .{});

    const lilo_conf = try boot.renderLiloConf(allocator, .{
        .disk = cfg.disk,
        .root_partition = root_part,
    });
    try writeTargetFile(io, "/etc/lilo.conf", lilo_conf);

    // lilo needs access to the real block device to write the MBR, and to
    // /proc for the running kernel's module list; bind-mount both into the
    // target before chrooting.
    const dev_path = try std.fmt.allocPrint(allocator, "{s}/dev", .{target_root});
    const proc_path = try std.fmt.allocPrint(allocator, "{s}/proc", .{target_root});
    try executor.run(.{ .argv = &.{ "mount", "--bind", "/dev", dev_path }, .description = "bind mount /dev" });
    defer {
        executor.run(.{ .argv = &.{ "umount", proc_path }, .description = "unmount /proc" }) catch {};
        executor.run(.{ .argv = &.{ "umount", dev_path }, .description = "unmount /dev" }) catch {};
    }
    try executor.run(.{ .argv = &.{ "mount", "--bind", "/proc", proc_path }, .description = "bind mount /proc" });

    try executor.run(.{
        .argv = &.{ "chroot", target_root, "lilo" },
        .description = "run lilo inside target root",
    });
}

test "fstab mounts labeled root boot and swap filesystems" {
    const fstab = renderFstab();
    try std.testing.expect(std.mem.indexOf(u8, fstab, "LABEL=root  /      ext4") != null);
    try std.testing.expect(std.mem.indexOf(u8, fstab, "LABEL=boot  /boot  ext4") != null);
    try std.testing.expect(std.mem.indexOf(u8, fstab, "LABEL=swap  none   swap") != null);
    try std.testing.expect(std.mem.indexOf(u8, fstab, "tmpfs       /dev/shm tmpfs") != null);
}
