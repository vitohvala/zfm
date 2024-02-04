const std = @import("std");
const system = std.os.system;
const stdout = std.io.getStdOut().writer();
const FileIcon = "";
const DirIcon = "";

const Hidden = enum {
    off,
    on,
};

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
pub fn clear() !void {
    try stdout.print("\x1b[2J", .{});
    try stdout.print("\x1b[H", .{});
}

pub fn print_files(files: std.ArrayList([]const u8), mode: Hidden, icon: []const u8) !void {
    switch (mode) {
        .on => {
            for (files.items) |item| {
                try stdout.print("{s} {s}\n", .{ icon, item });
            }
        },
        .off => {
            for (files.items) |item| {
                if (item[0] != '.')
                    std.debug.print("{s} {s}\n", .{ icon, item });
            }
        },
    }
}

pub fn main() !void {
    var bw = std.io.bufferedWriter(stdout);
    const stdin = std.io.getStdIn();
    _ = stdin;

    const arg_path: []const u8 = if (std.os.argv.len > 1) std.mem.span(@as([*:0]const u8, std.os.argv.ptr[1])) else ".";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var dirs = std.ArrayList([]const u8).init(gpa.allocator());
    defer dirs.deinit();
    var files = std.ArrayList([]const u8).init(gpa.allocator());
    defer files.deinit();

    //var term = Term{ .og_termios = undefined };
    //try term.enable_raw();
    //defer term.disable_raw() catch {};

    var dir = try std.fs.cwd().openDir(arg_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    try clear();
    while (try iter.next()) |file| {
        switch (file.kind) {
            .file => {
                try files.append(file.name);
            },
            .directory => {
                try dirs.append(file.name);
            },
            else => continue,
        }
    }
    try print_files(dirs, .on, DirIcon);
    try print_files(files, .on, FileIcon);
    //try stdout.print("\n", .{});
    try bw.flush(); // don't forget to flush!
}
