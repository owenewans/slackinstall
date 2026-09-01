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
        \\disk = {s}
        \\  bios = 0x80
        \\  max-partitions = 63
        \\vga = {s}
        \\lba32
        \\compact
        \\prompt
        \\timeout = 50
        \\image = /boot/vmlinuz
        \\  root = {s}
        \\  label = Slackware
        \\  read-only
        \\  append = "console=tty0 console=ttyS0,115200n8"
        \\
        // lilo predates virtio and doesn't know how to map devices like
        // /dev/vdaN to a BIOS disk number on its own ("Fatal: Linux
        // experimental device 0xfd00 needs to be defined"); the disk=/bios=
        // stanza above fixes that. harmless for real /dev/sd* disks too, so
        // it's always included rather than only for virtio.
        //
        // the append= line keeps kernel messages on both the video console
        // and a serial port. combined with the ttyS0 getty enabled in
        // /etc/inittab (see install.zig), this makes every install
        // reachable over a serial console out of the box - standard on
        // real hardware with IPMI/iLO and required for any cloud/VPS/VM
        // console, and confirmed necessary in testing: without it, a
        // headless qemu boot produces no visible output at all past LILO.
    , .{ cfg.disk, cfg.disk, cfg.vga, cfg.root_partition });
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

test "renderLiloConf includes a disk=/bios= stanza so virtio disks boot" {
    // without this, lilo fails on /dev/vda* with:
    // "Fatal: Linux experimental device 0xfd00 needs to be defined."
    // confirmed against a real qemu virtio-blk install.
    const allocator = std.testing.allocator;
    const out = try renderLiloConf(allocator, .{
        .disk = "/dev/vda",
        .root_partition = "/dev/vda3",
    });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "disk = /dev/vda\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bios = 0x80\n") != null);
}
