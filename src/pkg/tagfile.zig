// parser for slackware tagfile format: "name:TAG" per line, comments with '#'.
// tags: ADD (always installed), REC (recommended), OPT (optional), SKP (skip).
const std = @import("std");

pub const Tag = enum {
    add,
    rec,
    opt,
    skp,

    pub fn parse(s: []const u8) ?Tag {
        if (std.mem.eql(u8, s, "ADD")) return .add;
        if (std.mem.eql(u8, s, "REC")) return .rec;
        if (std.mem.eql(u8, s, "OPT")) return .opt;
        if (std.mem.eql(u8, s, "SKP")) return .skp;
        return null;
    }
};

pub const Entry = struct {
    name: []const u8,
    tag: Tag,
};

/// Parses tagfile content into a caller-owned slice of entries.
/// Entries reference slices of `content`, so `content` must outlive the result.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..sep], " \t");
        const tag_str = std.mem.trim(u8, line[sep + 1 ..], " \t");
        const tag = Tag.parse(tag_str) orelse continue;
        if (name.len == 0) continue;

        try entries.append(allocator, .{ .name = name, .tag = tag });
    }

    return entries.toOwnedSlice(allocator);
}

test "parse basic tagfile" {
    const content =
        \\# comment line
        \\aaa_base:ADD
        \\bash:ADD
        \\acpid:REC
        \\cpufrequtils:OPT
        \\
        \\some-unused:SKP
    ;
    const entries = try parse(std.testing.allocator, content);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expectEqualStrings("aaa_base", entries[0].name);
    try std.testing.expectEqual(Tag.add, entries[0].tag);
    try std.testing.expectEqual(Tag.rec, entries[2].tag);
    try std.testing.expectEqual(Tag.skp, entries[4].tag);
}

test "ignores malformed lines" {
    const content =
        \\no-colon-here
        \\name:UNKNOWNTAG
        \\ok:ADD
    ;
    const entries = try parse(std.testing.allocator, content);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("ok", entries[0].name);
}
