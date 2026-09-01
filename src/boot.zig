// bootloader configuration. slackware ships LILO by default; this renders
// /etc/lilo.conf and the command used to install it (must run inside chroot).
const std = @import("std");

pub const LiloConfig = struct {
    disk: []const u8, // e.g. "/dev/sda" (MBR target, not a partition)
    root_partition: []const u8, // e.g. "/dev/sda3"
    vga: []const u8 = "normal",
};

pub fn renderLiloConf(allocator: std.mem.Allocator, cfg: LiloConfig) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\boot = {s}
        \\vga = {s}
        \\lba32
        \\compact
        \\prompt
        \\timeout = 50
        \\image = /boot/vmlinuz
        \\  root = {s}
        \\  label = Slackware
        \\  read-only
        \\
    , .{ cfg.disk, cfg.vga, cfg.root_partition });
}

pub const installArgv: []const []const u8 = &.{"lilo"};

test "renderLiloConf embeds disk and root partition" {
    const allocator = std.testing.allocator;
    const out = try renderLiloConf(allocator, .{
        .disk = "/dev/sda",
        .root_partition = "/dev/sda3",
    });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "boot = /dev/sda\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "root = /dev/sda3\n") != null);
}
