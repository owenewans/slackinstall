// DNS resolver configuration: plain /etc/resolv.conf, or a local stub
// resolver config for DoH/DoT (unbound-style), avoiding a hard dependency on
// any single third-party client so the generated config stays inspectable.
const std = @import("std");
const config = @import("config.zig");

pub fn renderResolvConf(allocator: std.mem.Allocator, servers: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (servers) |s| {
        try buf.print(allocator, "nameserver {s}\n", .{s});
    }
    return buf.toOwnedSlice(allocator);
}

/// Renders an unbound forward-zone stanza for DoT (port 853, TLS) or DoH
/// (via unbound's forward-tls-upstream against a resolver's DoH-compatible
/// TLS endpoint). Written to /etc/unbound/conf.d/owenslackinstall-forward.conf.
pub fn renderUnboundForward(
    allocator: std.mem.Allocator,
    mode: config.DnsMode,
    servers: []const []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "forward-zone:\n    name: \".\"\n");

    switch (mode) {
        .plain => return renderResolvConf(allocator, servers),
        .dot => {
            try buf.appendSlice(allocator, "    forward-tls-upstream: yes\n");
            for (servers) |s| {
                try buf.print(allocator, "    forward-addr: {s}@853\n", .{s});
            }
        },
        .doh => {
            // unbound has no native DoH transport; DoH is terminated by a
            // local stub (e.g. dnscrypt-proxy) listening on 127.0.0.1:5300,
            // which this stanza forwards to.
            try buf.appendSlice(allocator, "    forward-addr: 127.0.0.1@5300\n");
        },
    }

    return buf.toOwnedSlice(allocator);
}

test "renderResolvConf lists every server" {
    const allocator = std.testing.allocator;
    const out = try renderResolvConf(allocator, &.{ "9.9.9.9", "1.1.1.1" });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "nameserver 9.9.9.9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nameserver 1.1.1.1\n") != null);
}

test "renderUnboundForward dot mode uses port 853" {
    const allocator = std.testing.allocator;
    const out = try renderUnboundForward(allocator, .dot, &.{"9.9.9.9"});
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "forward-addr: 9.9.9.9@853") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "forward-tls-upstream: yes") != null);
}

test "renderUnboundForward doh mode forwards to local stub" {
    const allocator = std.testing.allocator;
    const out = try renderUnboundForward(allocator, .doh, &.{"9.9.9.9"});
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "127.0.0.1@5300") != null);
}
