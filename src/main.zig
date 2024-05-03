const std = @import("std");
const system = std.os.system;
const stdout = std.io.getStdOut().writer();
const FileIcon = "";
const DirIcon = "";
const FG_FILES = 32;
const FG_DIR = 34;

const Hidden = enum {
    off,
    on,
};

const mode: Hidden = .on;
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
    bg: u8 = 40,
    fg: u8 = FG_DIR,

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
        term.iflag &= ~(system.IXON | system.ICRNL);
        term.oflag &= ~(system.OPOST);
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

    pub fn print_files(self: *Self, zfm: *Zfm, modeHI: Hidden, c: *Cursor) !void {
        switch (modeHI) {
            .on => {
                for (zfm.directories.items) |item| {
                    c.total_y += 1;
                    try self.stdout.print("\x1b[1;{d};{d}m", .{ self.bg, self.fg });
                    try self.stdout.print("\x1b[{d};{d}H{s}", .{ c.total_y, c.x, item });
                    //try self.stdout.print("\x1b[38;5;10;48;5;255m {s}\n", .{item});
                }
                for (zfm.files.items) |item| {
                    c.total_y += 1;
                    try self.stdout.print("\x1b[1;{d};{d}m", .{ self.bg, FG_FILES });
                    try self.stdout.print("\x1b[{d};{d}H{s}", .{ c.total_y, c.x, item });
                    //try self.stdout.print("\x1b[38;5;10;48;5;255m {s}\n", .{item});
                }
            },
            .off => {
                for (zfm.directories.items[zfm.start_pd..]) |item| {
                    c.total_y += 1;
                    try self.stdout.print("\x1b[1;{d};{d}m", .{ self.bg, self.fg });
                    try self.stdout.print("\x1b[{d};{d}H{s}", .{ c.total_y, c.x, item });
                }
                for (zfm.files.items[zfm.start_pf..]) |item| {
                    c.total_y += 1;
                    try self.stdout.print("\x1b[1;{d};{d}m", .{ self.bg, FG_FILES });
                    try self.stdout.print("\x1b[{d};{d}H{s}", .{ c.total_y, c.x, item });
                }
            },
        }
    }
    pub fn print_selected(self: *Self, cursor: *Cursor, chosen: []const u8) !void {
        try self.stdout.print("\x1b[{d};{d}H", .{ cursor.*.y, cursor.*.x });
        try self.stdout.print("\x1b[{};{}m\x1b[1;7m{s}", .{ self.bg, self.fg, chosen });
    }

    pub fn disable_wrap(self: *Self) !void {
        try self.stdout.print("\x1b[?7l", .{});
    }
    pub fn smcup(self: *Self) !void {
        try self.stdout.print("\x1b[?1049h", .{});
    }
    pub fn rmcup(self: *Self) !void {
        try self.stdout.print("\x1b[?1049l", .{});
    }
    pub fn enable_wrap(self: *Self) !void {
        try self.stdout.print("\x1b[?7h", .{});
    }
};

var max_bp: [std.fs.MAX_PATH_BYTES]u8 = undefined;

pub const Zfm = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList([]const u8) = undefined,
    directories: std.ArrayList([]const u8) = undefined,
    path: []const u8,
    start_pd: usize = 0,
    start_pf: usize = 0,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Zfm {
        return Zfm{
            .allocator = allocator,
            .directories = std.ArrayList([]const u8).init(allocator),
            .files = std.ArrayList([]const u8).init(allocator),
            .path = try std.fs.realpath(path, &max_bp),
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
    //TODO:
    //dodaj sym linkove
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
                //.sym_link => {
                //}
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
        cursor.total_y = 1;
        cursor.x = term.width / 2;
        try term.print_files(&zf_next, mode, cursor);
    }
    pub fn find_start(self: *Self) void {
        for (self.directories.items, 0..) |item, i| {
            if (item[4] != '.') {
                self.start_pd = i;
                break;
            }
        }
        for (self.files.items, 0..) |item, i| {
            if (item[4] != '.') {
                self.start_pf = i;
                break;
            }
        }
    }
};

pub fn file_extension(s: []const u8) usize {
    var index: usize = 0;
    for (s, 0..) |_, i| {
        const j = s.len - 1 - i;
        if (s[j] == '.') {
            index = j;
        }
    }
    return (index);
}

pub fn supported(chosen: []const u8) bool {
    const start = file_extension(chosen);
    if (std.mem.eql(u8, chosen[start..], ".jpg")) {
        return false;
    }
    return true;
}

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
                c.y = if (c.y > 2) c.y - 1 else @intCast(c.total_z + 1);
            },
            'B' => {
                c.y = if (c.y < c.total_z + 1) c.y + 1 else 2;
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

    try term.smcup();
    defer term.rmcup() catch {};

    try term.disable_wrap();
    defer term.enable_wrap() catch {};
    try term.hide_cursor();
    defer term.show_cursor() catch {};

    try zfm.populate();
    sort_list(&zfm.files);
    sort_list(&zfm.directories);
    try term.clear();

    if (mode == .off) {
        zfm.find_start();
    }
    var cursor = Cursor{
        .y = 2,
        .x = 1,
        .total_y = 1,
        .total_z = (zfm.directories.items.len - zfm.start_pd) + (zfm.files.items.len - zfm.start_pf),
    };
    var max_y: u16 = 0;

    while (!quit) {
        max_y = 0;
        try term.clear();
        try term.stdout.print("{s}\r\n", .{zfm.path});
        cursor.total_y = 1;
        try term.print_files(&zfm, mode, &cursor);

        var chosen: []const u8 = undefined;
        if ((zfm.directories.items.len - zfm.start_pd) > cursor.y - 2) {
            chosen = zfm.directories.items.ptr[cursor.y - 2 + zfm.start_pd];
            term.fg = FG_DIR;
            try zfm.next_directory(chosen[4..], &cursor, &term);
        } else {
            const start_ptr: usize = ((cursor.y - (zfm.directories.items.len - zfm.start_pd)) + zfm.start_pf) - 2;
            chosen = zfm.files.items.ptr[start_ptr];
            term.fg = FG_FILES;
            if (supported(chosen)) {
                const fullpath = try concat(gpa.allocator(), zfm.path, chosen[4..]);
                //const ext = std.fs.path.extension(fullpath);
                defer gpa.allocator().free(fullpath);
                var fil = try std.fs.cwd().openFile(fullpath, .{});
                defer fil.close();

                var buf_reader = std.io.bufferedReader(fil.reader());
                const reader = buf_reader.reader();

                var line = std.ArrayList(u8).init(gpa.allocator());
                defer line.deinit();

                cursor.x = term.width / 2;
                cursor.total_y = 2;

                const writer = line.writer();
                while (reader.streamUntilDelimiter(writer, '\n', null)) : (cursor.total_y += 1) {
                    defer line.clearRetainingCapacity();
                    if (cursor.total_y > term.height - 1) break;
                    const k = if (line.items.len > term.width - cursor.x) term.width - cursor.x else line.items.len;

                    try term.stdout.print("\x1b[m", .{});
                    try term.stdout.print("\x1b[{d};{d}H", .{ cursor.total_y, cursor.x });
                    try term.stdout.print("{s}\r\n", .{line.items.ptr[0..k]});
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => return err,
                }
            }
        }

        cursor.x = 1;
        try term.print_selected(&cursor, chosen);
        for (chosen.len..(term.width / 2)) |len| {
            _ = len;
            try term.stdout.print(" ", .{});
        }
        term.fg = FG_DIR;
        if (cursor.total_y > max_y) max_y = cursor.total_y;
        try term.stdout.print("\x1b[m", .{});

        try term.stdout.print("\x1b[{d};1H", .{max_y + 1});
        try key_pressed(&cursor, &quit);
    }
    try bw.flush(); // don't forget to flush!
}
