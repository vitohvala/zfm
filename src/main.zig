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

pub fn print_files(files: std.ArrayList([]const u8), mode: Hidden) !void {
    switch (mode) {
        .on => {
            for (files.items) |item| {
                try stdout.print("{s}\n", .{item});
            }
        },
        .off => {
            for (files.items) |item| {
                std.debug.print("{s}\n", .{item});
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
    defer {
        for (dirs.items) |f| gpa.allocator().free(f);
        dirs.deinit();
    }
    var files = std.ArrayList([]const u8).init(gpa.allocator());
    defer {
        for (files.items) |f| gpa.allocator().free(f);
        files.deinit();
    }
    //var term = Term{ .og_termios = undefined };
    //try term.enable_raw();
    //defer term.disable_raw() catch {};

    var dir = try std.fs.cwd().openDir(arg_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterateAssumeFirstIteration();
    try clear();
    while (try iter.next()) |file| {
        switch (file.kind) {
            .file => {
                const cmd = try std.fmt.allocPrint(gpa.allocator(), "{s} {s}", .{ FileIcon, file.name });
                errdefer gpa.allocator().free(cmd);
                try files.append(cmd);
            },
            .directory => {
                const cmd = try std.fmt.allocPrint(gpa.allocator(), "{s} {s}", .{ DirIcon, file.name });
                errdefer gpa.allocator().free(cmd);
                try dirs.append(cmd);
            },
            else => continue,
        }
    }
    try print_files(dirs, .on);
    try print_files(files, .on);
    //try stdout.print("\n", .{});
    try bw.flush(); // don't forget to flush!
}
