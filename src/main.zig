const std = @import("std");
const config = @import("config.zig");
const profile = @import("pkg/profile.zig");
const disk = @import("disk.zig");
const net = @import("net.zig");
const dns = @import("dns.zig");
const boot = @import("boot.zig");
const tui = @import("tui.zig");
const install = @import("install.zig");

// zig only auto-discovers `test` blocks in the file passed as the test
// root; without this, every test in every imported file (all of them,
// until this was caught) is silently skipped by `zig build test` even
// though `expect(false)` in any of those files still reports a passing
// build. `refAllDecls` forces every public declaration in this file's
// imports to be referenced, which pulls their tests in too.
test {
    std.testing.refAllDecls(@This());
}

const usage =
    \\owenslackinstall - a minimal installer for Slackware.
    \\
    \\usage:
    \\  owenslackinstall install                  interactive, menu-driven install
    \\  owenslackinstall plan   --config <file>    print the install plan from a json config
    \\  owenslackinstall apply  --config <file> -y execute a json config (scripted installs)
    \\  owenslackinstall profile <minimal|server|desktop>
    \\                                         list the packages a profile installs
    \\  owenslackinstall --help
    \\
    \\nothing is written to disk without confirmation: `install` asks before
    \\formatting anything, `apply` requires -y/--confirm.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        try out.writeAll(usage);
        return 0;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "profile")) {
        if (args.len < 3) {
            try err_out.writeAll("error: profile requires <minimal|server|desktop>\n");
            return 1;
        }
        const p = profile.Profile.parseName(args[2]) orelse {
            try err_out.print("error: unknown profile '{s}'\n", .{args[2]});
            return 1;
        };
        try out.print("# {s}: {s}\n", .{ args[2], p.description() });
        const list = try p.packageList(allocator);
        defer {
            for (list) |s| allocator.free(s);
            allocator.free(list);
        }
        for (list) |name| try out.print("{s}\n", .{name});
        try out.print("# {d} packages total\n", .{list.len});
        return 0;
    }

    if (std.mem.eql(u8, command, "install")) {
        return runInteractiveInstall(allocator, io, out, err_out) catch |e| {
            try err_out.print("error: {t}\n", .{e});
            return 1;
        };
    }

    if (std.mem.eql(u8, command, "plan") or std.mem.eql(u8, command, "apply")) {
        const apply_mode = std.mem.eql(u8, command, "apply");

        var config_path: ?[]const u8 = null;
        var confirmed = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
                config_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "-y") or std.mem.eql(u8, args[i], "--confirm")) {
                confirmed = true;
            }
        }

        const path = config_path orelse {
            try err_out.writeAll("error: --config <file.json> is required\n");
            return 1;
        };

        var parsed = config.loadFromJson(allocator, io, path) catch |e| {
            try err_out.print("error: failed to load config '{s}': {t}\n", .{ path, e });
            return 1;
        };
        defer parsed.deinit();

        const cfg = parsed.value.toConfig() catch |e| {
            try err_out.print("error: invalid config: {t}\n", .{e});
            return 1;
        };
        cfg.validate() catch |e| {
            try err_out.print("error: invalid config: {t}\n", .{e});
            return 1;
        };

        if (apply_mode and !confirmed) {
            try err_out.writeAll("error: apply requires -y/--confirm\n");
            return 1;
        }

        try printPlan(allocator, out, cfg);

        if (apply_mode) {
            try out.writeAll("\n# executing plan\n");
            try out.flush();
            install.run(allocator, io, out, cfg) catch |e| {
                try err_out.print("error: install failed: {t}\n", .{e});
                return 1;
            };
        }

        return 0;
    }

    try err_out.print("error: unknown command '{s}'\n\n", .{command});
    try err_out.writeAll(usage);
    return 1;
}

fn runInteractiveInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !u8 {
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buf);
    const session: tui.Session = .{
        .allocator = allocator,
        .io = io,
        .out = out,
        .in = &stdin_reader.interface,
    };

    try session.print("owenslackinstall - interactive install\n", .{});

    // disk selection: read real disks from /proc/partitions instead of
    // making the user guess or type a raw device path from memory.
    const proc_partitions = readProcPartitions(allocator, io) catch |e| {
        try err_out.print("error: could not read /proc/partitions: {t}\n", .{e});
        return 1;
    };
    defer allocator.free(proc_partitions);

    const disks = try tui.parseDisks(allocator, proc_partitions);
    defer {
        for (disks) |d| allocator.free(d.name);
        allocator.free(disks);
    }

    if (disks.len == 0) {
        try err_out.writeAll("error: no disks found in /proc/partitions\n");
        return 1;
    }

    var disk_labels: std.ArrayList([]const u8) = .empty;
    defer {
        for (disk_labels.items) |l| allocator.free(l);
        disk_labels.deinit(allocator);
    }
    for (disks) |d| {
        const label = try std.fmt.allocPrint(allocator, "/dev/{s} ({d} MB)", .{ d.name, d.size_kb / 1024 });
        try disk_labels.append(allocator, label);
    }

    const disk_idx = try session.menu("select a target disk (all data on it will be erased):", disk_labels.items, 0);
    const disk_path = try disks[disk_idx].devicePath(allocator);
    defer allocator.free(disk_path);

    const hostname = try session.text("hostname", "slackware");
    defer allocator.free(hostname);

    const profile_idx = try session.menu("select an install profile:", &.{
        "minimal - base system only",
        "server  - base, dev tools, networking, no X11",
        "desktop - full X11 desktop (xfce/kde)",
    }, 0);
    const chosen_profile: profile.Profile = switch (profile_idx) {
        0 => .minimal,
        1 => .server,
        else => .desktop,
    };

    // network interface selection: read real interfaces from /sys/class/net
    // instead of assuming eth0, since virtio/real NICs commonly show up as
    // enpXsY or similar. static addressing is not implemented, only which
    // interface DHCP runs on.
    const raw_interfaces = readNetworkInterfaceNames(allocator, io) catch |e| {
        try err_out.print("error: could not read /sys/class/net: {t}\n", .{e});
        return 1;
    };
    defer {
        for (raw_interfaces) |n| allocator.free(n);
        allocator.free(raw_interfaces);
    }
    const interfaces = try tui.parseInterfaces(allocator, raw_interfaces);
    defer {
        for (interfaces) |n| allocator.free(n);
        allocator.free(interfaces);
    }

    const interface: []const u8 = if (interfaces.len == 0)
        try allocator.dupe(u8, "eth0")
    else iface_blk: {
        const idx = try session.menu("select a network interface for dhcp:", interfaces, 0);
        break :iface_blk try allocator.dupe(u8, interfaces[idx]);
    };
    defer allocator.free(interface);

    const dns_idx = try session.menu("select a DNS mode:", &.{
        "plain - classic resolv.conf",
        "dot   - DNS-over-TLS via unbound",
        "doh   - DNS-over-HTTPS via a local stub",
    }, 0);
    const dns_mode: config.DnsMode = switch (dns_idx) {
        0 => .plain,
        1 => .dot,
        else => .doh,
    };

    const swap_str = try session.text("swap size in MB", "2048");
    defer allocator.free(swap_str);
    const swap_mb = std.fmt.parseInt(u32, swap_str, 10) catch {
        try err_out.writeAll("error: swap size must be a number\n");
        return 1;
    };

    const root_password = try session.password("root password");
    defer allocator.free(root_password);

    const cfg: config.Config = .{
        .disk = disk_path,
        .hostname = hostname,
        .profile = chosen_profile,
        .dns_mode = dns_mode,
        .swap_mb = swap_mb,
        .root_password = root_password,
        .network_interface = interface,
    };
    cfg.validate() catch |e| {
        try err_out.print("error: invalid configuration: {t}\n", .{e});
        return 1;
    };

    try session.print("\n--- install plan ---\n", .{});
    try printPlan(allocator, out, cfg);
    try out.flush();

    const proceed = try session.confirm(
        "this will erase all data on the selected disk. continue?",
    );
    if (!proceed) {
        try session.print("aborted, nothing was changed.\n", .{});
        return 0;
    }

    try session.print("\n# executing plan\n", .{});
    try out.flush();
    try install.run(allocator, io, out, cfg);
    return 0;
}

fn readProcPartitions(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/partitions", .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    // /proc/partitions reports a stat size of 0; positional reads based on
    // that size would return nothing, so this must stream instead.
    var reader = file.readerStreaming(io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}

/// Lists raw entry names under /sys/class/net (unfiltered, including "lo").
/// Returns an empty slice if sysfs isn't mounted rather than erroring, since
/// some minimal live environments may not have it.
fn readNetworkInterfaceNames(allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |n| allocator.free(n);
        list.deinit(allocator);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/net", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return list.toOwnedSlice(allocator),
        else => return e,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try list.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return list.toOwnedSlice(allocator);
}

fn printPlan(allocator: std.mem.Allocator, out: anytype, cfg: config.Config) !void {
    try out.print("owenslackinstall plan for {s} on {s}\n", .{ cfg.hostname, cfg.disk });
    try out.print("profile: {s}\n\n", .{@tagName(cfg.profile)});

    const layout: disk.Layout = .{ .disk = cfg.disk, .swap_mb = cfg.swap_mb };
    const steps = try disk.buildSteps(allocator, layout);
    defer disk.freeSteps(allocator, steps);
    try out.writeAll("disk steps:\n");
    for (steps) |s| {
        try out.print("  - {s}:", .{s.description});
        for (s.argv) |a| try out.print(" {s}", .{a});
        try out.writeAll("\n");
    }

    const list = try cfg.profile.packageList(allocator);
    defer {
        for (list) |s| allocator.free(s);
        allocator.free(list);
    }
    try out.print("\npackages: {d} total\n", .{list.len});
    try out.print("package mirror: {s}\n", .{cfg.package_mirror});
    try out.print("network interface: {s} (dhcp)\n", .{cfg.network_interface});

    try out.print("\ndns mode: {s}\n", .{@tagName(cfg.dns_mode)});
}
