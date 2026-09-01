// disk partitioning and filesystem creation.
// command *plans* are pure and unit-tested; execution is a thin, explicit
// wrapper around std.process.Child so a dry run never touches a real disk.
const std = @import("std");

pub const Step = struct {
    argv: []const []const u8,
    description: []const u8,
};

pub const Layout = struct {
    disk: []const u8, // e.g. "/dev/sda"
    swap_mb: u32,

    fn part(self: Layout, allocator: std.mem.Allocator, n: u8) ![]const u8 {
        // nvme/mmcblk devices need a 'p' separator before the partition number.
        const needs_p = std.mem.indexOf(u8, self.disk, "nvme") != null or
            std.mem.indexOf(u8, self.disk, "mmcblk") != null;
        if (needs_p) return std.fmt.allocPrint(allocator, "{s}p{d}", .{ self.disk, n });
        return std.fmt.allocPrint(allocator, "{s}{d}", .{ self.disk, n });
    }

    pub fn bootPartition(self: Layout, allocator: std.mem.Allocator) ![]const u8 {
        return self.part(allocator, 1);
    }
    pub fn swapPartition(self: Layout, allocator: std.mem.Allocator) ![]const u8 {
        return self.part(allocator, 2);
    }
    pub fn rootPartition(self: Layout, allocator: std.mem.Allocator) ![]const u8 {
        return self.part(allocator, 3);
    }
};

/// Builds an sfdisk script: 512M ext4 boot, `swap_mb` swap, remainder ext4 root.
pub fn buildPartitionScript(allocator: std.mem.Allocator, layout: Layout) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\label: gpt
        \\size=512MiB, type=linux
        \\size={d}MiB, type=swap
        \\type=linux
        \\
    , .{layout.swap_mb});
}

/// Frees a slice returned by `buildSteps`, including the partition path
/// strings embedded in the mkfs/mkswap steps.
pub fn freeSteps(allocator: std.mem.Allocator, steps: []Step) void {
    allocator.free(steps[1].argv[4]); // boot_part
    allocator.free(steps[2].argv[3]); // swap_part
    allocator.free(steps[3].argv[4]); // root_part
    for (steps) |s| allocator.free(s.argv);
    allocator.free(steps);
}

pub fn buildSteps(allocator: std.mem.Allocator, layout: Layout) ![]Step {
    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(allocator);

    const boot_part = try layout.bootPartition(allocator);
    const swap_part = try layout.swapPartition(allocator);
    const root_part = try layout.rootPartition(allocator);

    // argv slices below own `boot_part`/`swap_part`/`root_part` after this
    // point; `freeSteps` frees each argv element individually.
    try steps.append(allocator, .{
        .argv = try allocator.dupe([]const u8, &.{ "sfdisk", layout.disk }),
        .description = "partition disk from generated gpt script",
    });
    try steps.append(allocator, .{
        .argv = try allocator.dupe([]const u8, &.{ "mkfs.ext4", "-F", "-L", "boot", boot_part }),
        .description = "format boot partition as ext4",
    });
    try steps.append(allocator, .{
        .argv = try allocator.dupe([]const u8, &.{ "mkswap", "-L", "swap", swap_part }),
        .description = "initialize swap partition",
    });
    try steps.append(allocator, .{
        .argv = try allocator.dupe([]const u8, &.{ "mkfs.ext4", "-F", "-L", "root", root_part }),
        .description = "format root partition as ext4",
    });

    return steps.toOwnedSlice(allocator);
}

pub const Executor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dry_run: bool,

    pub fn run(self: Executor, step: Step) !void {
        if (self.dry_run) {
            var stdout_buf: [512]u8 = undefined;
            var stdout_writer: std.Io.File.Writer = .init(.stdout(), self.io, &stdout_buf);
            const w = &stdout_writer.interface;
            try w.print("[dry-run] {s}:", .{step.description});
            for (step.argv) |arg| try w.print(" {s}", .{arg});
            try w.writeAll("\n");
            try w.flush();
            return;
        }

        var child = try std.process.spawn(self.io, .{ .argv = step.argv });
        const term = try child.wait(self.io);
        switch (term) {
            .exited => |code| if (code != 0) return error.CommandFailed,
            else => return error.CommandFailed,
        }
    }
};

test "buildSteps produces expected partition device names for sd disks" {
    const allocator = std.testing.allocator;
    const layout: Layout = .{ .disk = "/dev/sda", .swap_mb = 2048 };
    const steps = try buildSteps(allocator, layout);
    defer freeSteps(allocator, steps);

    try std.testing.expectEqual(@as(usize, 4), steps.len);
    try std.testing.expectEqualStrings("/dev/sda1", steps[1].argv[4]);
    try std.testing.expectEqualStrings("/dev/sda2", steps[2].argv[3]);
    try std.testing.expectEqualStrings("/dev/sda3", steps[3].argv[4]);
}

test "buildSteps adds 'p' separator for nvme disks" {
    const allocator = std.testing.allocator;
    const layout: Layout = .{ .disk = "/dev/nvme0n1", .swap_mb = 4096 };
    const boot = try layout.bootPartition(allocator);
    defer allocator.free(boot);
    try std.testing.expectEqualStrings("/dev/nvme0n1p1", boot);
}

test "buildPartitionScript embeds swap size" {
    const allocator = std.testing.allocator;
    const layout: Layout = .{ .disk = "/dev/sda", .swap_mb = 1024 };
    const script = try buildPartitionScript(allocator, layout);
    defer allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "size=1024MiB, type=swap") != null);
}
