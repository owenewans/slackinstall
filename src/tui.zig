// interactive terminal prompts: arrow-free, no "type 1 to continue" nonsense.
// numbered menus with sane defaults, plain y/n confirmation, real disk
// discovery from /proc/partitions instead of asking the user to guess a path.
const std = @import("std");

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    in: *std.Io.Reader,

    pub fn print(self: Session, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt, args);
        try self.out.flush();
    }

    fn readLine(self: Session) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        while (true) {
            const byte = self.in.takeByte() catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            if (byte == '\n') break;
            if (byte == '\r') continue;
            try list.append(self.allocator, byte);
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// Prompts with a numbered menu of `options` and returns the chosen index.
    /// Empty input selects `default_index`. Re-prompts on invalid input.
    pub fn menu(self: Session, title: []const u8, options: []const []const u8, default_index: usize) !usize {
        try self.print("\n{s}\n", .{title});
        for (options, 0..) |opt, i| {
            const marker: []const u8 = if (i == default_index) " (default)" else "";
            try self.print("  {d}) {s}{s}\n", .{ i + 1, opt, marker });
        }
        while (true) {
            try self.print("> ", .{});
            const line = try self.readLine();
            defer self.allocator.free(line);
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) return default_index;
            const n = std.fmt.parseInt(usize, trimmed, 10) catch {
                try self.print("enter a number between 1 and {d}\n", .{options.len});
                continue;
            };
            if (n < 1 or n > options.len) {
                try self.print("enter a number between 1 and {d}\n", .{options.len});
                continue;
            }
            return n - 1;
        }
    }

    /// Prompts for a free-text value. Empty input returns a copy of `default`.
    /// Caller owns the returned slice.
    pub fn text(self: Session, prompt: []const u8, default: ?[]const u8) ![]const u8 {
        while (true) {
            if (default) |d| {
                try self.print("{s} [{s}]: ", .{ prompt, d });
            } else {
                try self.print("{s}: ", .{prompt});
            }
            const line = try self.readLine();
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) {
                self.allocator.free(line);
                if (default) |d| return self.allocator.dupe(u8, d);
                try self.print("this field is required\n", .{});
                continue;
            }
            const owned = try self.allocator.dupe(u8, trimmed);
            self.allocator.free(line);
            return owned;
        }
    }

    /// Prompts twice for a password with terminal echo disabled, retrying
    /// until both entries match. Caller owns the returned slice.
    pub fn password(self: Session, prompt: []const u8) ![]const u8 {
        while (true) {
            const first = try self.hiddenLine(prompt);
            const second = try self.hiddenLine("confirm password");
            if (std.mem.eql(u8, first, second)) {
                self.allocator.free(second);
                if (first.len == 0) {
                    self.allocator.free(first);
                    try self.print("password cannot be empty\n", .{});
                    continue;
                }
                return first;
            }
            self.allocator.free(first);
            self.allocator.free(second);
            try self.print("passwords did not match, try again\n", .{});
        }
    }

    fn hiddenLine(self: Session, prompt: []const u8) ![]u8 {
        const stdin_fd = std.posix.STDIN_FILENO;
        const original = std.posix.tcgetattr(stdin_fd) catch null;
        if (original) |orig| {
            var raw = orig;
            raw.lflag.ECHO = false;
            std.posix.tcsetattr(stdin_fd, .NOW, raw) catch {};
        }
        defer if (original) |orig| std.posix.tcsetattr(stdin_fd, .NOW, orig) catch {};

        try self.print("{s}: ", .{prompt});
        const line = try self.readLine();
        try self.print("\n", .{}); // terminal echo was off, so no newline was shown
        return line;
    }

    /// Plain y/N confirmation. Defaults to "no" on empty input, which is the
    /// safe default before anything destructive.
    pub fn confirm(self: Session, prompt: []const u8) !bool {
        while (true) {
            try self.print("{s} [y/N]: ", .{prompt});
            const line = try self.readLine();
            defer self.allocator.free(line);
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) return false;
            if (std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes")) return true;
            if (std.ascii.eqlIgnoreCase(trimmed, "n") or std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
            try self.print("please answer y or n\n", .{});
        }
    }
};

/// A block device discovered from /proc/partitions: whole disks only
/// (partitions themselves are filtered out), skipping loop/ram devices.
pub const Disk = struct {
    name: []const u8, // e.g. "sda", "nvme0n1"
    size_kb: u64,

    pub fn devicePath(self: Disk, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "/dev/{s}", .{self.name});
    }
};

/// Parses the content of /proc/partitions, returning only whole-disk entries.
/// Caller owns the returned slice; each `name` is a duplicate.
pub fn parseDisks(allocator: std.mem.Allocator, proc_partitions: []const u8) ![]Disk {
    var disks: std.ArrayList(Disk) = .empty;
    errdefer {
        for (disks.items) |d| allocator.free(d.name);
        disks.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, proc_partitions, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "major")) continue; // header

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // major
        _ = fields.next() orelse continue; // minor
        const blocks_str = fields.next() orelse continue;
        const name = fields.next() orelse continue;

        if (isPartitionName(name)) continue;
        if (std.mem.startsWith(u8, name, "loop")) continue;
        if (std.mem.startsWith(u8, name, "ram")) continue;
        if (std.mem.startsWith(u8, name, "sr")) continue; // optical drives

        const blocks = std.fmt.parseInt(u64, blocks_str, 10) catch continue;
        try disks.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .size_kb = blocks,
        });
    }

    return disks.toOwnedSlice(allocator);
}

/// Whole disks end in a letter (sda, vda) or digit+letter combos (nvme0n1);
/// partitions append a trailing number (sda1, nvme0n1p1). This distinguishes
/// them without needing sysfs access.
fn isPartitionName(name: []const u8) bool {
    if (name.len == 0) return false;
    const last = name[name.len - 1];
    if (!std.ascii.isDigit(last)) return false;
    // nvme/mmcblk disks look like "nvme0n1" (ends in digit, not a partition);
    // their partitions look like "nvme0n1p1". Treat trailing digit as a
    // partition only when preceded by a non-digit, non-'n' letter run that
    // isn't the nvme/mmcblk disk-number pattern.
    if (std.mem.indexOf(u8, name, "nvme") != null or std.mem.indexOf(u8, name, "mmcblk") != null) {
        return std.mem.indexOfScalar(u8, name, 'p') != null;
    }
    return true;
}

test "parseDisks filters partitions, loop and optical devices" {
    const sample =
        \\major minor  #blocks  name
        \\
        \\   8        0  244198584 sda
        \\   8        1     512000 sda1
        \\   8        2  243683840 sda2
        \\ 259        0  976762584 nvme0n1
        \\ 259        1     524288 nvme0n1p1
        \\   7        0      65536 loop0
        \\  11        0       1048 sr0
    ;
    const allocator = std.testing.allocator;
    const disks = try parseDisks(allocator, sample);
    defer {
        for (disks) |d| allocator.free(d.name);
        allocator.free(disks);
    }

    try std.testing.expectEqual(@as(usize, 2), disks.len);
    try std.testing.expectEqualStrings("sda", disks[0].name);
    try std.testing.expectEqualStrings("nvme0n1", disks[1].name);
}

test "Disk.devicePath formats /dev path" {
    const allocator = std.testing.allocator;
    const d: Disk = .{ .name = "sda", .size_kb = 1000 };
    const path = try d.devicePath(allocator);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/dev/sda", path);
}

/// Filters raw entries from /sys/class/net down to real, selectable network
/// interfaces: excludes loopback, and sorts for a stable menu order.
/// Caller owns the returned slice; each name is a duplicate of the
/// corresponding input.
pub fn parseInterfaces(allocator: std.mem.Allocator, names: []const []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |n| allocator.free(n);
        list.deinit(allocator);
    }
    for (names) |name| {
        if (std.mem.eql(u8, name, "lo")) continue;
        try list.append(allocator, try allocator.dupe(u8, name));
    }
    const owned = try list.toOwnedSlice(allocator);
    std.mem.sort([]const u8, owned, {}, lessThanStr);
    return owned;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "parseInterfaces excludes loopback and sorts" {
    const allocator = std.testing.allocator;
    const names = try parseInterfaces(allocator, &.{ "eth0", "lo", "wlan0" });
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("eth0", names[0]);
    try std.testing.expectEqualStrings("wlan0", names[1]);
}

test "parseInterfaces returns empty for loopback-only input" {
    const allocator = std.testing.allocator;
    const names = try parseInterfaces(allocator, &.{"lo"});
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 0), names.len);
}
