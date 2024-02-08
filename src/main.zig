const std = @import("std");
const system = std.os.system;
const stdout = std.io.getStdOut().writer();
const FileIcon = "";
const DirIcon = "";

const Hidden = enum {
    off,
    on,
};

const Key = enum {
    UP,
    DOWN,
    RIGHT,
    LEFT,
    NOT_IMPLEMENTED,
};

const File = struct {
    file: []const u8,
};

pub const Term = struct {
    handle: system.fd_t = std.io.getStdIn().handle,
    og_termios: std.os.termios,
    stdout: @TypeOf(std.io.getStdOut().writer()) = std.io.getStdOut().writer(),

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
    pub fn clear(self: *Self) !void {
        try self.stdout.print("\x1b[2J", .{});
        try self.stdout.print("\x1b[H", .{});
    }
    pub fn print_files(self: *Self, files: std.ArrayList([]const u8), mode: Hidden) !void {
        switch (mode) {
            .on => {
                for (files.items) |item| {
                    try self.stdout.print("{s}\n", .{item});
                    //try self.stdout.print("\x1b[38;5;10;48;5;255m {s}\n", .{item});
                }
            },
            .off => {
                for (files.items) |item| {
                    if (item[0] == '.')
                        try self.stdout.print("{s}\n", .{item});
                }
            },
        }
    }
};

pub const Zfm = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList([]const u8) = undefined,
    directories: std.ArrayList([]const u8) = undefined,
    path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Zfm {
        return Zfm{
            .allocator = allocator,
            .directories = std.ArrayList([]const u8).init(allocator),
            .files = std.ArrayList([]const u8).init(allocator),
            .path = path,
        };
    }

    pub fn deinit_items(self: *Self, alist: *std.ArrayList([]const u8)) void {
        for (alist.items) |f|
            self.allocator.free(f);
        alist.deinit();
    }

    pub fn deinit(self: *Self) void {
        self.deinit_items(&self.directories);
        self.deinit_items(&self.files);
    }

    pub fn ff_helper(self: *Self, file: *std.ArrayList([]const u8), icon: []const u8, name: []const u8) !void {
        const cmd = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ icon, name });
        errdefer self.allocator.free(cmd);
        try file.append(cmd);
    }

    pub fn populate(self: *Self) !void {
        var dir = try std.fs.cwd().openDir(self.path, .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |file| {
            switch (file.kind) {
                .file => {
                    try self.ff_helper(&self.files, FileIcon, file.name);
                },
                .directory => {
                    try self.ff_helper(&self.directories, DirIcon, file.name);
                },
                else => continue,
            }
        }
    }
};

pub fn key_pressed() !Key {
    const stdin = std.io.getStdIn().reader();
    var buf: [4]u8 = undefined;
    const nread = try stdin.read(&buf);
    std.debug.assert(nread >= 0);

    if (nread > 2 and buf[0] == '\x1b' and buf[1] == '[') {
        switch (buf[2]) {
            'A' => return .UP,
            'B' => return .DOWN,
            'C' => return .RIGHT,
            'D' => return .LEFT,
            else => return .NOT_IMPLEMENTED,
        }
    }
}

pub fn sort_list(list: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, list.items, {}, struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.f);
}

pub fn main() !void {
    var bw = std.io.bufferedWriter(stdout);

    const arg_path: []const u8 =
        if (std.os.argv.len > 1) std.mem.span(@as([*:0]const u8, std.os.argv.ptr[1])) else ".";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var zfm = try Zfm.init(gpa.allocator(), arg_path);
    defer zfm.deinit();

    var term = Term{ .og_termios = undefined };
    try term.enable_raw();
    defer term.disable_raw() catch {};

    try zfm.populate();
    sort_list(&zfm.files);
    sort_list(&zfm.directories);
    try term.clear();

    try term.print_files(zfm.directories, .on);
    try term.print_files(zfm.files, .on);

    try bw.flush(); // don't forget to flush!
}
