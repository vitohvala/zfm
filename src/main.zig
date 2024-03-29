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
    width: u16 = undefined,
    height: u16 = undefined,

    const Self = @This();

    pub fn term_size(self: *Self) !void {
        var ws: std.os.system.winsize = undefined;

        const err = std.os.linux.ioctl(self.handle, std.os.system.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.os.errno(err) != .SUCCESS) {
            return error.IoctlError;
        }
        self.width = ws.ws_col;
        self.height = ws.ws_row;
    }

    pub fn enable_raw(self: *Self) !void {
        self.og_termios = try std.os.tcgetattr(self.handle);
        var term = self.og_termios;
        term.iflag &= ~(system.IXON);
        term.lflag &= ~(system.ICANON | system.ECHO | system.ISIG);

        term.cc[system.V.MIN] = 0;
        term.cc[system.V.TIME] = 1;

        try std.os.tcsetattr(self.handle, .NOW, term);
    }

    pub fn disable_raw(self: *Self) !void {
        try std.os.tcsetattr(self.handle, .DRAIN, self.og_termios);
    }
    pub fn clear(self: *Self) !void {
        try self.stdout.print("\x1b[2J", .{});
        try self.stdout.print("\x1b[H", .{});
    }
    pub fn print_files(self: *Self, files: std.ArrayList([]const u8), mode: Hidden, y: *u16, x: u16) !void {
        switch (mode) {
            .on => {
                for (files.items) |item| {
                    y.* += 1;
                    try self.stdout.print("\x1b[{d};{d}H{s}", .{ y.*, x, item });
                    //try self.stdout.print("\x1b[38;5;10;48;5;255m {s}\n", .{item});
                }
            },
            .off => {
                for (files.items) |item| {
                    if (item[4] != '.') {
                        try self.stdout.print("\x1b[{d};{d}H{s}", .{ y.*, x, item });
                    }
                }
            },
        }
    }
    pub fn disable_wrap(self: *Self) !void {
        try self.stdout.print("\x1b[?7l", .{});
    }
    pub fn enable_wrap(self: *Self) !void {
        try self.stdout.print("\x1b[?7h", .{});
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
    try term.term_size();
    try term.enable_raw();
    defer term.disable_raw() catch {};

    try term.disable_wrap();
    defer term.enable_wrap() catch {};

    try zfm.populate();
    sort_list(&zfm.files);
    sort_list(&zfm.directories);
    try term.clear();

    var y: u16 = 0;
    var max_y: u16 = 0;

    try term.print_files(zfm.directories, .on, &y, 1);
    try term.print_files(zfm.files, .on, &y, 1);

    const x = term.width / 2;
    try term.stdout.print("\x1b[1;1H\x1b[38;5;255;48;5;75m{s}", .{zfm.directories.items.ptr[0]});
    for (zfm.directories.items.ptr[0].len..(x)) |len| {
        _ = len;
        try term.stdout.print(" ", .{});
    }
    if (y > max_y) max_y = y;
    try term.stdout.print("\x1b[m", .{});

    const dir_next = zfm.directories.items.ptr[0][4..];

    var tempal = std.ArrayList([]const u8).init(gpa.allocator());
    //defer tempal.deinit();
    try tempal.append(arg_path);
    if (arg_path[arg_path.len - 1] != '/') try tempal.append("/");
    try tempal.append(dir_next);

    const nn = try tempal.toOwnedSlice();
    defer gpa.allocator().free(nn);

    const temp = try std.mem.join(gpa.allocator(), "", nn);
    defer gpa.allocator().free(temp);

    var zf_next = try Zfm.init(gpa.allocator(), temp);
    defer zf_next.deinit();

    try zf_next.populate();

    y = 0;
    try term.print_files(zf_next.directories, .on, &y, x);
    try term.print_files(zf_next.files, .on, &y, x);

    if (y > max_y) max_y = y;
    try term.stdout.print("\x1b[{};1H", .{max_y + 1});
    try bw.flush(); // don't forget to flush!
}
