const std = @import("std");
const system = std.os.linux;
const FileIcon = "";
const DirIcon = "";
const FG_FILES = 32;
const FG_DIR = 34;

var hidden: bool = false;
//var sorted: bool = false;

// TODO:
// Add functionality from enum
// Add config file
// add file permissions
// add the time of the creation

const Key = enum {
    UP,
    DOWN,
    RIGHT,
    LEFT,
    HIDE,
    QUIT,
    //    DELETE,
    //    RENAME,
    //    MOVE,
    //    COPY,
    //    PASTE,
    //    NEW_FILE,
    //    NEW_DIR,
    NOT_IMPLEMENTED,
};

const Cursor = struct {
    y: u16,
    x: u16,
    total_y: u16,
};

const FileItems = struct {
    icon: []const u8,
    name: []const u8,
    kind: std.fs.File.Kind,
};
pub fn format_bytes(bytes: u64, alloc: std.mem.Allocator) ![]u8 {
    const symbols = " KMG";
    if (bytes == 0) return std.fmt.allocPrint(alloc, "0 ", .{});
    const size_float = @as(f64, @floatFromInt(bytes));
    const exp: u64 = @as(u64, @intFromFloat(@min(@log(size_float) / @log(1024.00), symbols.len - 1)));
    const fm = size_float / std.math.pow(f64, 1024.00, @as(f64, @floatFromInt(exp)));

    const ret = try std.fmt.allocPrint(alloc, "{d:.1}{c}", .{ fm, symbols[exp] });
    return ret;
}

pub const Term = struct {
    handle: system.fd_t = std.io.getStdIn().handle,
    og_termios: std.posix.termios,
    stdout: @TypeOf(std.io.getStdOut().writer()) = std.io.getStdOut().writer(),
    width: u16 = undefined,
    height: u16 = undefined,
    bg: u8 = 48,
    fg: u8 = FG_DIR,

    const Self = @This();

    pub fn term_size(self: *Self) !void {
        var ws: std.posix.winsize = undefined;

        const err = system.ioctl(self.handle, system.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(err) != .SUCCESS) {
            return error.IoctlError;
        }

        self.width = ws.ws_col;
        self.height = ws.ws_row;
    }

    pub fn enable_raw(self: *Self) !void {
        self.og_termios = try std.posix.tcgetattr(self.handle);
        var term = self.og_termios;
        term.iflag.IXON = false;
        term.iflag.ICRNL = false;
        term.oflag.OPOST = false;
        term.lflag.ICANON = false;
        term.lflag.ECHO = false;
        term.lflag.ISIG = false;

        term.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        term.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(self.handle, .FLUSH, term);
    }

    pub fn disable_raw(self: *Self) !void {
        try std.posix.tcsetattr(self.handle, .DRAIN, self.og_termios);
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
    fn print_entries(self: *Self, zfm: *Zfm, c: *Cursor) !void {
        var k: usize = 0;

        const entries = zfm.entries.items[zfm.start_e..];

        for (entries) |item| {
            if (item.name[0] == '.' and hidden == true)
                continue;
            self.fg = if (item.kind == .file) FG_FILES else FG_DIR;
            c.total_y += 1;
            if (c.total_y > self.height - 1) break;
            k = @min(item.name.len, (self.width / 2));
            try self.stdout.print("\x1b[1;{d};{d}m", .{ self.fg, self.bg });
            try self.stdout.print("\x1b[{d};{d}H{s} {s}", .{ c.total_y, c.x, item.icon, item.name[0..k] });
        }
        self.fg = FG_DIR;
    }
    pub fn print_selected(self: *Self, cursor: *Cursor, chosen: []const u8, fmt_bytes: []u8) !void {
        const num_len = fmt_bytes.len;
        const k = @min(chosen.len, (self.width / 2) - (num_len - 1));
        try self.stdout.print("\x1b[{d};{d}H", .{ cursor.y, cursor.x });
        try self.stdout.print("\x1b[{};{}m\x1b[1;7m{s}", .{ self.fg, self.bg, chosen[0..k] });

        var tmp: usize = chosen.len;
        while (tmp < (self.width / 2) - (num_len)) : (tmp += 1) {
            try self.stdout.print(" ", .{});
        }
        try self.stdout.print("\x1b[{};{}m\x1b[1;7m{s}", .{ self.fg, self.bg, fmt_bytes });
    }
    pub fn init(self: *Self) !void {
        try self.term_size();
        try self.smcup();
        try self.clear();
        try self.enable_raw();
        try self.disable_wrap();
        try self.hide_cursor();
    }

    pub fn deinit(self: *Self) !void {
        try self.disable_raw();
        try self.enable_wrap();
        try self.show_cursor();
        try self.rmcup();
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
    pub fn right_print(self: *Self, msg: []const u8) !void {
        const x = self.width / 2;
        const y = 2;
        try self.stdout.print("\x1b[{d};{d}H", .{ y, x });
        try self.stdout.print("\x1b[41;37;1m<{s}>\x1b[m", .{msg});
    }
};

var max_bp: [std.fs.MAX_PATH_BYTES]u8 = undefined;

pub const Zfm = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(FileItems) = undefined,
    path: []const u8,
    start_e: usize = 0,
    selected: usize = 0,
    //scheduled: []Key = undefined,
    next_empty: bool = false,
    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, path: []const u8) !Zfm {
        return Zfm{
            .allocator = allocator,
            .entries = std.ArrayList(FileItems).init(allocator),
            .path = try std.fs.realpath(path, &max_bp),
        };
    }

    pub fn init_new(self: *Self, path: []const u8) !void {
        self.deinit();
        self.* = try Zfm.create(self.allocator, path);
        try self.populate();
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.icon);
        }
        self.entries.deinit();
    }

    //TODO:
    //dodaj sym linkove
    pub fn populate(self: *Self) !void {
        var dir = try std.fs.openDirAbsolute(self.path, .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |file| {
            var icon: []const u8 = undefined;
            switch (file.kind) {
                .file => {
                    icon = try self.allocator.dupe(u8, FileIcon);
                    try self.entries.append(.{ .name = try self.allocator.dupe(u8, file.name), .icon = icon, .kind = file.kind });
                },
                .directory => {
                    icon = try self.allocator.dupe(u8, DirIcon);
                    try self.entries.append(.{ .name = try self.allocator.dupe(u8, file.name), .icon = icon, .kind = file.kind });
                },
                //.sym_link => {
                //}
                else => continue,
            }
        }
        sort_df(&self.entries);
    }

    pub fn next_directory(self: *Self, chosen: []const u8, cursor: *Cursor, term: *Term) !Zfm {
        const temp = try path_concat(self.allocator, self.path, chosen);
        defer self.allocator.free(temp);

        var zf_next = try Zfm.create(self.allocator, temp);
        try zf_next.populate();
        cursor.total_y = 1;
        cursor.x = term.width / 2;
        //try term.print_files(&zf_next, mode, cursor);
        return zf_next;
    }
    pub fn inc_selected(self: *Self) void {
        self.selected += 1;
        if (hidden) {
            while (self.entries.items[self.selected].name[0] == '.') {
                if (self.selected < self.entries.items.len - 1) self.selected += 1 else break;
            }
        }
    }
    pub fn dec_selected(self: *Self) void {
        if (self.selected > 0) self.selected -= 1;
        if (hidden) {
            while (self.entries.items[self.selected].name[0] == '.') {
                if (self.selected > 0) self.selected -= 1 else break;
            }
        }
    }
};

pub fn key_pressed() !Key {
    const stdin = std.io.getStdIn().reader();
    var buf: [4]u8 = undefined;
    const nread = try stdin.read(&buf);
    std.debug.assert(nread >= 0);

    if (nread == 1) {
        switch (buf[0]) {
            'q', 'q' & 0x1f, 0x1b => return .QUIT, //quit.* = true,
            ('h' | 'H') & 0x1f => {
                return .HIDE;
            },
            'h', 'H' => return .LEFT,
            'j', 'J' => return .DOWN,
            'k', 'K' => return .UP,
            'l', 'L' => return .RIGHT,
            else => return .NOT_IMPLEMENTED,
        }
    }

    if (nread > 2 and buf[0] == '\x1b' and buf[1] == '[') {
        switch (buf[2]) {
            'A' => return .UP,
            'B' => return .DOWN,
            'C' => return .RIGHT,
            'D' => return .LEFT,
            else => return .NOT_IMPLEMENTED,
        }
    }
    return .NOT_IMPLEMENTED;
}

pub fn handle_keypress(key: Key, zfm: *Zfm, c: *Cursor, t: *Term, chosen: []const u8) !bool {
    switch (key) {
        .LEFT => {
            if (!std.mem.eql(u8, zfm.path, "/")) {
                const t_path = std.fs.path.dirname(zfm.path);
                try zfm.init_new(t_path.?);
                c.y = 2;
            }
        },
        .RIGHT => {
            if (zfm.entries.items[zfm.selected].kind != .file and !zfm.next_empty) {
                const t_path = try path_concat(zfm.allocator, zfm.path, chosen);
                defer zfm.allocator.free(t_path);
                try zfm.init_new(t_path);
                c.y = 2;
            }
        },
        .UP => {
            if (c.y <= t.height / 4 and zfm.start_e > 0) {
                zfm.start_e -= 1;
                c.y = t.height / 4;
                zfm.dec_selected();
            } else if (c.y > 2) {
                c.y -= 1;
                zfm.dec_selected();
            }
        },
        .DOWN => {
            var enlen = zfm.entries.items.len + 1;
            if (hidden) {
                const entries = zfm.entries.items[zfm.start_e..];
                for (entries) |item| {
                    if (item.name[0] == '.') enlen -= 1;
                }
            }
            const theight = (t.height - 1) - (t.height / 4);
            const __min = @min(enlen, t.height - 1);
            if (c.y >= theight and zfm.start_e < zfm.entries.items.len - (t.height - 2)) {
                zfm.start_e += 1;
                c.y = theight;
                zfm.inc_selected();
            } else if (c.y < __min and zfm.selected < zfm.entries.items.len - 1) {
                c.y += 1;
                zfm.inc_selected();
            }
        },
        .HIDE => {
            hidden = !hidden;
            c.y = 2;
        },
        .QUIT => return true,
        .NOT_IMPLEMENTED => return false,
    }
    return false;
}

pub fn sort_list(list: *std.ArrayList(FileItems)) void {
    std.mem.sort(FileItems, list.items, {}, struct {
        fn f(_: void, a: FileItems, b: FileItems) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.f);
}

pub fn sort_df(list: *std.ArrayList(FileItems)) void {
    std.mem.sort(FileItems, list.items, {}, struct {
        fn f(_: void, a: FileItems, b: FileItems) bool {
            return @intFromEnum(a.kind) < @intFromEnum(b.kind);
        }
    }.f);
}

pub fn path_concat(alloc: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    if (a[a.len - 1] != std.fs.path.sep) {
        return try std.mem.concat(alloc, u8, &[_][]const u8{ a, std.fs.path.sep_str, b });
    }
    return std.mem.concat(alloc, u8, &[_][]const u8{ a, b });
}

pub fn main() !void {
    var quit = false;

    const arg_path: []const u8 =
        if (std.os.argv.len > 1) std.mem.span(@as([*:0]const u8, std.os.argv.ptr[1])) else ".";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var zfm = try Zfm.create(gpa.allocator(), arg_path);
    defer zfm.deinit();

    var term = Term{ .og_termios = undefined };
    try term.init();
    defer term.deinit() catch {};
    var cursor = Cursor{
        .y = 2,
        .x = 1,
        .total_y = 1,
    };

    try zfm.populate();
    var sel_size: u64 = 0;

    while (!quit) {
        try term.clear();
        try term.term_size();
        cursor.total_y = 1;
        try term.stdout.print("{s}\r\n", .{zfm.path});

        try term.print_entries(&zfm, &cursor);

        const chosen: []const u8 = zfm.entries.items[zfm.selected].name;

        if (zfm.entries.items[zfm.selected].kind == .directory) {
            if (zfm.next_directory(chosen, &cursor, &term)) |zf_next| {
                var zfm2 = zf_next;
                defer zfm2.deinit();
                const fullpath = try path_concat(gpa.allocator(), zfm.path, chosen);
                defer gpa.allocator().free(fullpath);
                var dirsel = try std.fs.cwd().openDir(fullpath, .{});
                defer dirsel.close();
                const md = try dirsel.metadata();
                sel_size = md.size();
                if (zfm2.entries.items.len == 0) {
                    zfm.next_empty = true;
                    try term.right_print("EMPTY");
                } else {
                    try term.print_entries(&zfm2, &cursor);
                }
            } else |err| {
                try term.right_print(@errorName(err));
                zfm.next_empty = true;
            }
        } else {
            term.fg = FG_FILES;
            const fullpath = try path_concat(gpa.allocator(), zfm.path, chosen);
            //const ext = std.fs.path.extension(fullpath);
            defer gpa.allocator().free(fullpath);
            var fil = try std.fs.cwd().openFile(fullpath, .{});
            defer fil.close();

            const md = try fil.metadata();
            sel_size = md.size();
            var is_binary = false;
            var buffer: [1024]u8 = undefined;
            const bytesRead = try fil.reader().read(&buffer);
            for (buffer[0..bytesRead]) |byte| {
                if (byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') {
                    is_binary = true;
                    break;
                }
            }

            if (is_binary) {
                try term.right_print("Cannot Read");
            } else {
                try fil.seekTo(0);
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
                    const k = @min(line.items.len, term.width - cursor.x);

                    try term.stdout.print("\x1b[m", .{});
                    try term.stdout.print("\x1b[{d};{d}H", .{ cursor.total_y, cursor.x });
                    try term.stdout.print("{s}\r\n", .{line.items.ptr[0..k]});
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => return err,
                }
            }
        }

        const selected = try std.mem.concat(gpa.allocator(), u8, &[_][]const u8{ zfm.entries.items[zfm.selected].icon, " ", chosen });

        cursor.x = 1;
        const fmt_bytes = try format_bytes(sel_size, gpa.allocator());
        try term.print_selected(&cursor, selected, fmt_bytes);
        gpa.allocator().free(selected);
        gpa.allocator().free(fmt_bytes);

        term.fg = FG_DIR;
        try term.stdout.print("\x1b[m", .{});

        const key: Key = try key_pressed();
        quit = try handle_keypress(key, &zfm, &cursor, &term, chosen);
        zfm.next_empty = false;
    }
}
