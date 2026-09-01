// non-interactive install configuration, analogous to archinstall's
// user_configuration.json. loaded from a JSON file passed via --config.
const std = @import("std");
const builtin = @import("builtin");
const profile = @import("pkg/profile.zig");

/// Matches the architecture this binary was built for: an x86_64 build
/// defaults to the slackware64 tree, an x86 build to the plain slackware
/// (32-bit) tree. Both trees ship the same package set for 15.0 (see
/// src/pkg/index.zig), just built for different CPUs.
pub const default_package_mirror = switch (builtin.target.cpu.arch) {
    .x86_64 => "http://slackware.osuosl.org/slackware64-15.0/slackware64",
    .x86 => "http://slackware.osuosl.org/slackware-15.0/slackware",
    else => @compileError("slackinstall only supports x86_64 and x86 (i686) targets"),
};

pub const DnsMode = enum {
    plain, // classic /etc/resolv.conf nameserver entries
    doh, // DNS-over-HTTPS via a local stub resolver
    dot, // DNS-over-TLS via a local stub resolver

    pub fn parseName(name: []const u8) ?DnsMode {
        if (std.mem.eql(u8, name, "plain")) return .plain;
        if (std.mem.eql(u8, name, "doh")) return .doh;
        if (std.mem.eql(u8, name, "dot")) return .dot;
        return null;
    }
};

pub const Config = struct {
    disk: []const u8, // e.g. "/dev/sda"
    hostname: []const u8,
    profile: profile.Profile,
    dns_mode: DnsMode = .plain,
    dns_servers: []const []const u8 = &.{ "9.9.9.9", "149.112.112.112" },
    package_mirror: []const u8 = default_package_mirror,
    /// The interface DHCP runs on during install and that the target's
    /// rc.inet1.conf is written for, e.g. "eth0" or "enp0s3". Only DHCP is
    /// supported; static addressing is not implemented.
    network_interface: []const u8 = "eth0",
    /// Plaintext used only to generate a SHA-512 hash in the live environment;
    /// the plaintext itself is never written into the target filesystem. If
    /// null, root stays locked until a password is set later.
    root_password: ?[]const u8 = null,
    swap_mb: u32 = 2048,

    pub fn validate(self: Config) !void {
        if (self.disk.len == 0) return error.MissingDisk;
        if (self.hostname.len == 0) return error.MissingHostname;
        if (!std.mem.startsWith(u8, self.disk, "/dev/")) return error.InvalidDiskPath;
        if (!std.mem.startsWith(u8, self.package_mirror, "http://") and
            !std.mem.startsWith(u8, self.package_mirror, "https://"))
        {
            return error.InvalidPackageMirror;
        }
        if (self.swap_mb == 0) return error.InvalidSwapSize;
        if (self.network_interface.len == 0 or self.network_interface.len > 15) {
            return error.InvalidNetworkInterface;
        }
        for (self.network_interface) |c| {
            const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_';
            if (!ok) return error.InvalidNetworkInterface;
        }
        if (self.root_password) |password| {
            if (password.len == 0 or std.mem.indexOfAny(u8, password, "\r\n") != null) {
                return error.InvalidRootPassword;
            }
        }
        for (self.hostname) |c| {
            const ok = std.ascii.isAlphanumeric(c) or c == '-';
            if (!ok) return error.InvalidHostname;
        }
    }
};

pub fn loadFromJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(RawConfig) {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const content = try file_reader.interface.allocRemaining(allocator, .limited(1 << 20));
    defer allocator.free(content);
    return std.json.parseFromSlice(RawConfig, allocator, content, .{ .allocate = .alloc_always });
}

/// JSON-shaped mirror of Config, using strings for enum fields.
pub const RawConfig = struct {
    disk: []const u8,
    hostname: []const u8,
    profile: []const u8,
    dns_mode: []const u8 = "plain",
    dns_servers: []const []const u8 = &.{ "9.9.9.9", "149.112.112.112" },
    package_mirror: []const u8 = default_package_mirror,
    root_password: ?[]const u8 = null,
    swap_mb: u32 = 2048,
    network_interface: []const u8 = "eth0",

    pub fn toConfig(self: RawConfig) !Config {
        const p = profile.Profile.parseName(self.profile) orelse return error.InvalidProfile;
        const d = DnsMode.parseName(self.dns_mode) orelse return error.InvalidDnsMode;
        return .{
            .disk = self.disk,
            .hostname = self.hostname,
            .profile = p,
            .dns_mode = d,
            .dns_servers = self.dns_servers,
            .package_mirror = self.package_mirror,
            .root_password = self.root_password,
            .swap_mb = self.swap_mb,
            .network_interface = self.network_interface,
        };
    }
};

test "validate rejects non /dev disk paths" {
    const cfg: Config = .{
        .disk = "sda",
        .hostname = "box",
        .profile = .minimal,
    };
    try std.testing.expectError(error.InvalidDiskPath, cfg.validate());
}

test "validate rejects invalid hostname characters" {
    const cfg: Config = .{
        .disk = "/dev/sda",
        .hostname = "bad_host!",
        .profile = .minimal,
    };
    try std.testing.expectError(error.InvalidHostname, cfg.validate());
}

test "validate accepts sane config" {
    const cfg: Config = .{
        .disk = "/dev/sda",
        .hostname = "web-01",
        .profile = .server,
    };
    try cfg.validate();
}

test "validate rejects zero swap and unusable root passwords" {
    var cfg: Config = .{
        .disk = "/dev/sda",
        .hostname = "box",
        .profile = .minimal,
        .swap_mb = 0,
    };
    try std.testing.expectError(error.InvalidSwapSize, cfg.validate());

    cfg.swap_mb = 2048;
    cfg.root_password = "";
    try std.testing.expectError(error.InvalidRootPassword, cfg.validate());

    cfg.root_password = "first\nsecond";
    try std.testing.expectError(error.InvalidRootPassword, cfg.validate());
}

test "validate rejects unusable network interface names" {
    var cfg: Config = .{
        .disk = "/dev/sda",
        .hostname = "box",
        .profile = .minimal,
        .network_interface = "",
    };
    try std.testing.expectError(error.InvalidNetworkInterface, cfg.validate());

    cfg.network_interface = "eth0; rm -rf /";
    try std.testing.expectError(error.InvalidNetworkInterface, cfg.validate());

    cfg.network_interface = "enp0s3";
    try cfg.validate();
}

test "RawConfig.toConfig rejects unknown profile" {
    const raw: RawConfig = .{
        .disk = "/dev/sda",
        .hostname = "box",
        .profile = "bogus",
    };
    try std.testing.expectError(error.InvalidProfile, raw.toConfig());
}
