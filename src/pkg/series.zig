// slackware 15.0 disk sets ("series") and their embedded tagfiles.
// source: https://mirrors.slackware.com/slackware/slackware64-15.0/slackware64/<set>/tagfile
const std = @import("std");
const tagfile = @import("tagfile.zig");

pub const Series = enum {
    a, // base system
    ap, // applications
    d, // program development
    e, // emacs
    f, // faq/docs
    k, // kernel source
    kde, // kde desktop
    l, // libraries
    n, // networking
    t, // tex
    tcl, // tcl/tk
    x, // x11 base
    xap, // x applications
    xfce, // xfce desktop
    y, // games

    pub fn label(self: Series) []const u8 {
        return switch (self) {
            .a => "a",
            .ap => "ap",
            .d => "d",
            .e => "e",
            .f => "f",
            .k => "k",
            .kde => "kde",
            .l => "l",
            .n => "n",
            .t => "t",
            .tcl => "tcl",
            .x => "x",
            .xap => "xap",
            .xfce => "xfce",
            .y => "y",
        };
    }

    pub fn content(self: Series) []const u8 {
        return switch (self) {
            .a => @embedFile("../data/tagfiles/a.tagfile"),
            .ap => @embedFile("../data/tagfiles/ap.tagfile"),
            .d => @embedFile("../data/tagfiles/d.tagfile"),
            .e => @embedFile("../data/tagfiles/e.tagfile"),
            .f => @embedFile("../data/tagfiles/f.tagfile"),
            .k => @embedFile("../data/tagfiles/k.tagfile"),
            .kde => @embedFile("../data/tagfiles/kde.tagfile"),
            .l => @embedFile("../data/tagfiles/l.tagfile"),
            .n => @embedFile("../data/tagfiles/n.tagfile"),
            .t => @embedFile("../data/tagfiles/t.tagfile"),
            .tcl => @embedFile("../data/tagfiles/tcl.tagfile"),
            .x => @embedFile("../data/tagfiles/x.tagfile"),
            .xap => @embedFile("../data/tagfiles/xap.tagfile"),
            .xfce => @embedFile("../data/tagfiles/xfce.tagfile"),
            .y => @embedFile("../data/tagfiles/y.tagfile"),
        };
    }

    pub fn entries(self: Series, allocator: std.mem.Allocator) ![]tagfile.Entry {
        return tagfile.parse(allocator, self.content());
    }
};

pub const all: []const Series = &.{
    .a, .ap, .d, .e, .f, .k, .kde, .l, .n, .t, .tcl, .x, .xap, .xfce, .y,
};

test "every series tagfile is embeddable and parseable" {
    inline for (all) |s| {
        const entries = try s.entries(std.testing.allocator);
        defer std.testing.allocator.free(entries);
    }
}

test "base series contains expected packages" {
    const entries = try Series.a.entries(std.testing.allocator);
    defer std.testing.allocator.free(entries);

    var found_bash = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "bash")) found_bash = true;
    }
    try std.testing.expect(found_bash);
}
