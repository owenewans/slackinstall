// network + hostname configuration file generation for slackware's native
// /etc/rc.d/rc.inet1.conf and /etc/HOSTNAME (no NetworkManager dependency).
const std = @import("std");

pub const NetworkMode = union(enum) {
    dhcp: struct { interface: []const u8 = "eth0" },
    static: struct {
        interface: []const u8 = "eth0",
        address: []const u8,
        netmask: []const u8,
        gateway: []const u8,
    },
};

pub fn renderHostname(allocator: std.mem.Allocator, hostname: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n", .{hostname});
}

pub fn renderHosts(allocator: std.mem.Allocator, hostname: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\127.0.0.1       localhost {s}
        \\::1             localhost {s}
        \\
    , .{ hostname, hostname });
}

pub fn renderRcInet1Conf(allocator: std.mem.Allocator, mode: NetworkMode) ![]const u8 {
    return switch (mode) {
        .dhcp => |d| std.fmt.allocPrint(allocator,
            \\IFNAME[0]="{s}"
            \\IPADDR[0]=""
            \\USE_DHCP[0]="yes"
            \\DHCP_HOSTNAME[0]=""
            \\
        , .{d.interface}),
        .static => |s| std.fmt.allocPrint(allocator,
            \\IFNAME[0]="{s}"
            \\IPADDR[0]="{s}"
            \\NETMASK[0]="{s}"
            \\USE_DHCP[0]="no"
            \\GATEWAY="{s}"
            \\
        , .{ s.interface, s.address, s.netmask, s.gateway }),
    };
}

test "renderRcInet1Conf dhcp mode" {
    const allocator = std.testing.allocator;
    const out = try renderRcInet1Conf(allocator, .{ .dhcp = .{ .interface = "eth0" } });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "USE_DHCP[0]=\"yes\"") != null);
}

test "renderRcInet1Conf static mode includes gateway" {
    const allocator = std.testing.allocator;
    const out = try renderRcInet1Conf(allocator, .{ .static = .{
        .interface = "eth0",
        .address = "192.168.1.10",
        .netmask = "255.255.255.0",
        .gateway = "192.168.1.1",
    } });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "GATEWAY=\"192.168.1.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "USE_DHCP[0]=\"no\"") != null);
}

test "renderHosts includes hostname on both loopback lines" {
    const allocator = std.testing.allocator;
    const out = try renderHosts(allocator, "web-01");
    defer allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    var count: usize = 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "web-01") != null) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
