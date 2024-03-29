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
const Cursor = struct {
    y: u16,
    x: u16,
    total_y: u16,
    total_z: usize,
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

        term.cc[system.V.MIN] = 1;
        term.cc[system.V.TIME] = 1;

        try std.os.tcsetattr(self.handle, .NOW, term);
    }

    pub fn disable_raw(self: *Self) !void {
        try std.os.tcsetattr(self.handle, .DRAIN, self.og_termios);
    }

    pub fn hide_cursor(self: *Self) !void {
        try self.stdout.print("\x1b[?25l", .{});
    }
    pub fn show_cursor(self: *Self) !void {
        try self.stdout.print("\x1b[?25h", .{});
    }
    pub fn clear(self: *Self) !void {
        try self.stdout.print("\x1b[2J", .{});
        try self.stdout.print("\x1b[H", .{});
    }
    pub fn print_files(self: *Self, files: std.ArrayList([]const u8), mode: Hidden, c: *Cursor) !void {
        switch (mode) {
            .on => {
                for (files.items) |item| {
                    c.total_y += 1;
                    try self.stdout.print("\x1b[{d};{d}H{s}", .{ c.total_y, c.x, item });
                    //try self.stdout.print("\x1b[38;5;10;48;5;255m {s}\n", .{item});
                }
            },
            .off => {
                for (files.items) |item| {
                    if (item[4] != '.') {
                        try self.stdout.print("\x1b[{d};{d}H{s}", .{ c.total_y, c.x, item });
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
    pub fn next_directory(self: *Self, chosen: []const u8, cursor: *Cursor, term: *Term) !void {
        const temp = try concat(self.allocator, self.path, chosen);
        defer self.allocator.free(temp);

        var zf_next = try Zfm.init(self.allocator, temp);
        defer zf_next.deinit();
        try zf_next.populate();
        cursor.total_y = 0;
        cursor.x = term.width / 2;
        try term.print_files(zf_next.directories, .on, cursor);
        try term.print_files(zf_next.files, .on, cursor);
    }
};

pub fn key_pressed(c: *Cursor, quit: *bool) !void {
    const stdin = std.io.getStdIn().reader();
    var buf: [4]u8 = undefined;
    const nread = try stdin.read(&buf);
    std.debug.assert(nread >= 0);

    if (nread == 1) {
        switch (buf[0]) {
            'q', 'q' & 0x1f, 0x1b => quit.* = true,
            else => quit.* = false,
        }
    }

    if (nread > 2 and buf[0] == '\x1b' and buf[1] == '[') {
        switch (buf[2]) {
            'A' => {
                c.y = if (c.y > 1) c.y - 1 else @intCast(c.total_z);
            },
            'B' => {
                c.y = if (c.y < c.total_z) c.y + 1 else 1;
            },
            'C' => {
                c.x = if (c.x > 1) c.x - 1 else 1;
            },
            'D' => {
                c.x = if (c.y > 0) c.x + 1 else 1;
            },
            else => c.x = c.x,
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

pub fn concat(alloc: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    var al = std.ArrayList([]const u8).init(alloc);
    try al.append(a);
    if (a[a.len - 1] != '/') try al.append("/");
    try al.append(b);
    const help = try al.toOwnedSlice();
    const fullpath = try std.mem.join(alloc, "", help);
    alloc.free(help);
    return fullpath;
}

pub fn main() !void {
    var bw = std.io.bufferedWriter(stdout);
    var quit = false;

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
    try term.hide_cursor();
    defer term.show_cursor() catch {};

    try zfm.populate();
    sort_list(&zfm.files);
    sort_list(&zfm.directories);
    try term.clear();

    var cursor = Cursor{
        .y = 1,
        .x = 1,
        .total_y = 0,
        .total_z = zfm.directories.items.len + zfm.files.items.len,
    };
    var max_y: u16 = 0;

    while (!quit) {
        max_y = 0;
        try term.clear();
        cursor.total_y = 0;
        try term.print_files(zfm.directories, .on, &cursor);
        try term.print_files(zfm.files, .on, &cursor);

        var chosen: []const u8 = undefined;
        if (zfm.directories.items.len > cursor.y - 1) {
            chosen = zfm.directories.items.ptr[cursor.y - 1];
            try zfm.next_directory(chosen[4..], &cursor, &term);
        } else {
            chosen = zfm.files.items.ptr[cursor.y - zfm.directories.items.len - 1];
            const fullpath = try concat(gpa.allocator(), zfm.path, chosen[4..]);
            defer gpa.allocator().free(fullpath);
            var fil = try std.fs.cwd().openFile(fullpath, .{});
            defer fil.close();

            var buf_reader = std.io.bufferedReader(fil.reader());
            const reader = buf_reader.reader();

            var line = std.ArrayList(u8).init(gpa.allocator());
            defer line.deinit();

            cursor.x = term.width / 2;
            cursor.total_y = 1;

            const writer = line.writer();
            while (reader.streamUntilDelimiter(writer, '\n', null)) : (cursor.total_y += 1) {
                defer line.clearRetainingCapacity();
                if (cursor.total_y > term.height - 1) break;

                try term.stdout.print("\x1b[{d};{d}H{s}\n", .{ cursor.total_y, cursor.x, line.items });
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
        }

        cursor.x = 1;
        try term.stdout.print("\x1b[{d};{d}H", .{ cursor.y, cursor.x });
        try term.stdout.print("\x1b[38;5;255;48;5;75m{s}", .{chosen});
        for (chosen.len..(term.width / 2)) |len| {
            _ = len;
            try term.stdout.print(" ", .{});
        }
        if (cursor.total_y > max_y) max_y = cursor.total_y;
        try term.stdout.print("\x1b[m", .{});

        try term.stdout.print("\x1b[{d};1H", .{max_y + 1});
        try key_pressed(&cursor, &quit);
    }
    try bw.flush(); // don't forget to flush!
}
