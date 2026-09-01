const std = @import("std");
const config = @import("config.zig");
const profile = @import("pkg/profile.zig");
const disk = @import("disk.zig");
const net = @import("net.zig");
const dns = @import("dns.zig");
const boot = @import("boot.zig");

const usage =
    \\slackinstall - a minimal, non-interactive-friendly installer for Slackware.
    \\
    \\usage:
    \\  slackinstall plan   --config <file.json>   print the full install plan and exit
    \\  slackinstall apply  --config <file.json> --yes-i-am-sure   execute the plan
    \\  slackinstall profile <minimal|server|desktop>   list packages for a profile
    \\  slackinstall --help
    \\
    \\by default nothing is written to disk. apply requires --yes-i-am-sure.
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

    if (std.mem.eql(u8, command, "plan") or std.mem.eql(u8, command, "apply")) {
        const apply_mode = std.mem.eql(u8, command, "apply");

        var config_path: ?[]const u8 = null;
        var confirmed = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
                config_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--yes-i-am-sure")) {
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
            try err_out.writeAll("error: apply requires --yes-i-am-sure\n");
            return 1;
        }

        try printPlan(allocator, out, cfg);

        if (apply_mode) {
            try out.writeAll("\n# executing plan\n");
            try out.flush();
            try executePlan(allocator, io, cfg);
        }

        return 0;
    }

    try err_out.print("error: unknown command '{s}'\n\n", .{command});
    try err_out.writeAll(usage);
    return 1;
}

fn printPlan(allocator: std.mem.Allocator, out: anytype, cfg: config.Config) !void {
    try out.print("slackinstall plan for {s} on {s}\n", .{ cfg.hostname, cfg.disk });
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

    try out.print("\ndns mode: {s}\n", .{@tagName(cfg.dns_mode)});
}

fn executePlan(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !void {
    const layout: disk.Layout = .{ .disk = cfg.disk, .swap_mb = cfg.swap_mb };
    const steps = try disk.buildSteps(allocator, layout);
    defer disk.freeSteps(allocator, steps);
    // dry_run stays true here deliberately: real block-device execution needs
    // root, a target block device and package installer wiring that isn't
    // implemented yet. see readme.md roadmap.
    const executor: disk.Executor = .{ .allocator = allocator, .io = io, .dry_run = true };
    for (steps) |s| try executor.run(s);
}
