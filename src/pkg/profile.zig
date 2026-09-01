// install profiles, modeled after archinstall's minimal/server/desktop presets,
// mapped onto slackware's native ADD/REC/OPT/SKP tagfile system per disk series.
const std = @import("std");
const series = @import("series.zig");
const tagfile = @import("tagfile.zig");

pub const Profile = enum {
    minimal, // ADD only, base system series (a) plus bare networking (n)
    server, // ADD + REC across base, apps, dev, libs, networking (no X11)
    desktop, // ADD + REC across everything including X11 + xfce + kde

    pub fn parseName(name: []const u8) ?Profile {
        if (std.mem.eql(u8, name, "minimal")) return .minimal;
        if (std.mem.eql(u8, name, "server")) return .server;
        if (std.mem.eql(u8, name, "desktop")) return .desktop;
        return null;
    }

    pub fn description(self: Profile) []const u8 {
        return switch (self) {
            .minimal => "base system only: a + n series, ADD packages",
            .server => "base, dev, libs, apps, networking: ADD + REC, no X11",
            .desktop => "everything including X11, xfce and kde: ADD + REC",
        };
    }

    fn seriesFor(self: Profile) []const series.Series {
        return switch (self) {
            .minimal => &.{ .a, .n },
            .server => &.{ .a, .ap, .d, .l, .n, .t, .tcl },
            .desktop => series.all,
        };
    }

    fn includesTag(self: Profile, tag: tagfile.Tag) bool {
        return switch (tag) {
            .add => true,
            .rec => self != .minimal,
            .opt, .skp => false,
        };
    }

    /// Returns the sorted, deduplicated package list for this profile.
    /// Caller owns the returned slice and each contained string is a duplicate
    /// (safe to use after freeing intermediate tagfile buffers).
    pub fn packageList(self: Profile, allocator: std.mem.Allocator) ![][]const u8 {
        var set: std.StringHashMap(void) = .init(allocator);
        defer set.deinit();

        for (self.seriesFor()) |s| {
            const entries = try s.entries(allocator);
            defer allocator.free(entries);
            for (entries) |e| {
                if (!self.includesTag(e.tag)) continue;
                if (set.contains(e.name)) continue;
                const owned = try allocator.dupe(u8, e.name);
                try set.put(owned, {});
            }
        }

        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(allocator);
        var it = set.keyIterator();
        while (it.next()) |k| try list.append(allocator, k.*);

        const owned_list = try list.toOwnedSlice(allocator);
        std.mem.sort([]const u8, owned_list, {}, lessThan);
        return owned_list;
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

test "minimal profile is small and has no X11 packages" {
    const allocator = std.testing.allocator;
    const list = try Profile.minimal.packageList(allocator);
    defer {
        for (list) |s| allocator.free(s);
        allocator.free(list);
    }

    try std.testing.expect(list.len > 0);
    try std.testing.expect(list.len < 100);
    for (list) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "xorg-server"));
    }
}

test "desktop profile is a superset of server profile" {
    const allocator = std.testing.allocator;
    const server_list = try Profile.server.packageList(allocator);
    defer {
        for (server_list) |s| allocator.free(s);
        allocator.free(server_list);
    }
    const desktop_list = try Profile.desktop.packageList(allocator);
    defer {
        for (desktop_list) |s| allocator.free(s);
        allocator.free(desktop_list);
    }

    try std.testing.expect(desktop_list.len > server_list.len);
}

test "profile parseName roundtrip" {
    try std.testing.expectEqual(Profile.minimal, Profile.parseName("minimal").?);
    try std.testing.expectEqual(Profile.server, Profile.parseName("server").?);
    try std.testing.expectEqual(Profile.desktop, Profile.parseName("desktop").?);
    try std.testing.expect(Profile.parseName("bogus") == null);
}
