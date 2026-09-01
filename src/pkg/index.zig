// maps short package names (as used in tagfiles/profiles) to their exact,
// versioned filename and repository location within slackware64 15.0, e.g.
// "aaa_base" -> "a/aaa_base-15.0-x86_64-3.txz". Generated once from the
// official PACKAGES.TXT and embedded, same approach as the tagfiles: this is
// a frozen snapshot of slackware 15.0, not a live index.
const std = @import("std");

const raw = @embedFile("../data/pkgindex.tsv");

pub const Entry = struct {
    name: []const u8,
    /// relative path under the slackware64 tree, e.g. "a/aaa_base-15.0-x86_64-3.txz"
    path: []const u8,
};

/// Parses the embedded index. Caller owns the returned slice; entries
/// reference the embedded data directly (no allocation per string).
pub fn parse(allocator: std.mem.Allocator) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        try entries.append(allocator, .{
            .name = line[0..sep],
            .path = line[sep + 1 ..],
        });
    }
    return entries.toOwnedSlice(allocator);
}

/// Looks up a single package by short name. O(n); fine for install-time use
/// (called at most once per package in a profile, not in a hot loop).
pub fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

pub fn packageUrl(allocator: std.mem.Allocator, mirror_base: []const u8, entry: Entry) ![]const u8 {
    const base = std.mem.trimEnd(u8, mirror_base, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.path });
}

test "parse loads a non-trivial number of entries" {
    const allocator = std.testing.allocator;
    const entries = try parse(allocator);
    defer allocator.free(entries);
    try std.testing.expect(entries.len > 1000);
}

test "find resolves known packages" {
    const allocator = std.testing.allocator;
    const entries = try parse(allocator);
    defer allocator.free(entries);

    const bash = find(entries, "bash") orelse return error.NotFound;
    try std.testing.expect(std.mem.startsWith(u8, bash.path, "a/bash-"));

    const lilo = find(entries, "lilo") orelse return error.NotFound;
    try std.testing.expect(std.mem.startsWith(u8, lilo.path, "a/lilo-"));

    try std.testing.expect(find(entries, "does-not-exist-xyz") == null);
}

test "packageUrl builds the full mirror url" {
    const allocator = std.testing.allocator;
    const url = try packageUrl(allocator, "http://mirror.example/slackware64/", .{ .name = "bash", .path = "a/bash-5.1.016-x86_64-1.txz" });
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "http://mirror.example/slackware64/a/bash-5.1.016-x86_64-1.txz",
        url,
    );
}

test "every tagfile-referenced package resolves in the index" {
    const allocator = std.testing.allocator;
    const series_mod = @import("series.zig");
    const entries = try parse(allocator);
    defer allocator.free(entries);

    inline for (series_mod.all) |s| {
        const tf_entries = try s.entries(allocator);
        defer allocator.free(tf_entries);
        for (tf_entries) |e| {
            if (find(entries, e.name) == null) {
                std.debug.print("missing from package index: {s}\n", .{e.name});
                return error.MissingPackage;
            }
        }
    }
}
