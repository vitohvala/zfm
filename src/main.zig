const std = @import("std");
const system = std.os.system;

pub const Term = struct {
    handle: system.fd_t = std.io.getStdIn().handle,
    og_termios: std.os.termios,

    const Self = @This();

    pub fn enable_raw(self: *Self) !void {
        self.og_termios = try std.os.tcgetattr(self.handle);
        var term = self.og_termios;
        term.iflag &= ~(system.IXON);
        term.lflag &= ~(system.ICANON | system.ECHO | system.ISIG);

        term.cc[system.V.MIN] = 1;
        term.cc[system.V.TIME] = 1;

        try std.os.tcsetattr(self.handle, .FLUSH, term);
    }

    pub fn disable_raw(self: *Self) !void {
        try std.os.tcsetattr(self.handle, .FLUSH, self.og_termios);
    }
};

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn();
    _ = stdin;
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const arg_path: []const u8 = if (std.os.argv.len > 1) std.mem.span(@as([*:0]const u8, std.os.argv.ptr[1])) else ".";

    var term = Term{ .og_termios = undefined };
    try term.enable_raw();
    defer term.disable_raw() catch {};

    var dir = try std.fs.cwd().openDir(arg_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        std.debug.print(" {s} ", .{entry.name});
    }
    try stdout.print("\n", .{});
    try bw.flush(); // don't forget to flush!
}
