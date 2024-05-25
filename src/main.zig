const std = @import("std");
const system = std.os.system;
const FileIcon = "";
const DirIcon = "";
const FG_FILES = 32;
const FG_DIR = 34;
var mode: bool = true;

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

    pub fn term_size(self: *Self) !bool {
        var ws: std.os.system.winsize = undefined;

        const err = std.os.linux.ioctl(self.handle, std.os.system.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.os.errno(err) != .SUCCESS) {
            return error.IoctlError;
        }

        if (ws.ws_col == self.width) return false;
        if (ws.ws_row == self.height) return false;

        self.width = ws.ws_col;
        self.height = ws.ws_row;

        return true;
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

    pub fn print_files(self: *Self, zfm: *Zfm, c: *Cursor) !void {
        var k: usize = 0;
        for (zfm.directories.items[zfm.start_pd..zfm.end_pd]) |item| {
            c.total_y += 1;
            k = if (item.len > self.width / 2) self.width / 2 else item.len;
            try self.stdout.print("\x1b[1;{d};{d}m", .{ self.bg, self.fg });
            try self.stdout.print("\x1b[{d};{d}H{s}", .{ c.total_y, c.x, item[0..k] });
        }
        for (zfm.files.items[zfm.start_pf..zfm.end_pf]) |item| {
            c.total_y += 1;
            k = if (item.len > self.width / 2) self.width / 2 else item.len;
            try self.stdout.print("\x1b[1;{d};{d}m", .{ self.bg, FG_FILES });
            try self.stdout.print("\x1b[{d};{d}H{s}", .{ c.total_y, c.x, item[0..k] });
        }
    }
    pub fn print_selected(self: *Self, cursor: *Cursor, chosen: []const u8) !void {
        const k = if (chosen.len > (self.width / 2)) (self.width / 2) else chosen.len;
        try self.stdout.print("\x1b[{d};{d}H", .{ cursor.y, cursor.x });
        try self.stdout.print("\x1b[{};{}m\x1b[1;7m{s}", .{ self.bg, self.fg, chosen[0..k] });
    }
    pub fn init(self: *Self) !void {
        _ = try self.term_size();
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
    pub fn right_print(self: *Self, cursor: *Cursor, msg: []const u8) !void {
        cursor.x = self.width / 2;
        cursor.total_y = 2;
        try self.stdout.print("\x1b[{d};{d}H", .{ cursor.total_y, cursor.x });
        try self.stdout.print("\x1b[41;37;1m<{s}>", .{msg});
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
    tzero_f: usize = 0,
    tzero_d: usize = 0,
    end_pd: usize = 0,
    end_pf: usize = 0,
    next_empty: bool = false,
    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, path: []const u8) !Zfm {
        return Zfm{
            .allocator = allocator,
            .directories = std.ArrayList([]const u8).init(allocator),
            .files = std.ArrayList([]const u8).init(allocator),
            .path = try std.fs.realpath(path, &max_bp),
        };
    }

    pub fn init(self: *Self, path: []const u8, term: *Term) !void {
        self.deinit();
        self.* = try Zfm.create(self.allocator, path);
        try self.populate();
        sort_list(&self.directories);
        sort_list(&self.files);
        self.find_start();
        self.get_endp(term);
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
        var dir = try std.fs.openDirAbsolute(self.path, .{ .iterate = true });
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

    pub fn next_directory(self: *Self, chosen: []const u8, cursor: *Cursor, term: *Term) !Zfm {
        const temp = try concat(self.allocator, self.path, chosen);
        defer self.allocator.free(temp);

        var zf_next = try Zfm.create(self.allocator, temp);
        zf_next.populate() catch |err| return err;
        cursor.total_y = 1;
        cursor.x = term.width / 2;
        //try term.print_files(&zf_next, mode, cursor);
        return zf_next;
    }
    pub fn find_start(self: *Self) void {
        for (self.directories.items, 0..) |item, i| {
            if (item[4] != '.') {
                self.start_pd = i;
                self.tzero_d = i;
                break;
            }
        }
        for (self.files.items, 0..) |item, i| {
            if (item[4] != '.') {
                self.start_pf = i;
                self.tzero_f = i;
                break;
            }
        }

        if (mode) {
            self.start_pf = 0;
            self.start_pd = 0;
            self.tzero_f = 0;
            self.tzero_d = 0;
        }
    }
    pub fn get_endp(self: *Self, term: *Term) void {
        self.end_pd = if (self.directories.items.len > term.height) term.height - 1 + self.start_pd else self.directories.items.len;
        const tmp_h = term.height - (self.end_pd - self.start_pd) - 1;
        self.end_pf = if (self.files.items.len > tmp_h) tmp_h + self.start_pf else self.files.items.len;
    }
};

pub fn supported(chosen: []const u8) bool {
    const not_supported: [19][]const u8 = .{ ".jpg", ".png", ".pdf", ".jpeg", "zip", "iso", "svg", "webp", "doc", "docx", "pdf", "torrent", "PDF", "rar", "7z", "pptx", "ISO", "mkv", "parts" };
    for (not_supported) |not| {
        if (std.mem.endsWith(u8, chosen, not)) {
            return false;
        }
    }
    return true;
}

pub fn key_pressed(c: *Cursor, quit: *bool, zfm: *Zfm, term: *Term, chosen: []const u8) !void {
    const stdin = std.io.getStdIn().reader();
    var buf: [4]u8 = undefined;
    const nread = try stdin.read(&buf);
    std.debug.assert(nread >= 0);

    if (nread == 1) {
        switch (buf[0]) {
            'q', 'q' & 0x1f, 0x1b => quit.* = true,
            ('h' | 'H') & 0x1f => {
                mode = !mode;
                zfm.find_start();
                zfm.get_endp(term);
                c.y = 2;
                c.total_z = (zfm.directories.items.len - zfm.start_pd) + (zfm.files.items.len - zfm.start_pf);
            },
            else => quit.* = false,
        }
    }

    if (nread > 2 and buf[0] == '\x1b' and buf[1] == '[') {
        switch (buf[2]) {
            'A' => {
                if (c.y > 2) {
                    c.y -= 1;
                } else if (c.y <= 2 and (zfm.start_pd > zfm.tzero_d or zfm.start_pf > zfm.tzero_f)) {
                    if (zfm.start_pf > zfm.tzero_f) zfm.start_pf -= 1 else zfm.start_pd -= 1;
                    if (zfm.end_pf > zfm.start_pf) zfm.end_pf -= 1 else zfm.end_pd -= 1;
                    c.y = 2;
                }
            },
            'B' => {
                if (c.y < term.height and c.y < c.total_z + 1)
                    c.y += 1
                else if (c.y >= term.height and (zfm.end_pf < zfm.files.items.len or zfm.end_pd < zfm.directories.items.len)) {
                    c.y = term.height;
                    if (zfm.start_pd < zfm.directories.items.len) zfm.start_pd += 1 else zfm.start_pf += 1;
                    if (zfm.end_pd < zfm.directories.items.len) zfm.end_pd += 1 else zfm.end_pf += 1;
                }
            },
            // Desno
            'C' => {
                if ((zfm.directories.items.len - zfm.start_pd) > c.y - 2 and !zfm.next_empty) {
                    const t_path = try concat(zfm.allocator, zfm.path, chosen);
                    defer zfm.allocator.free(t_path);
                    try zfm.init(t_path, term);
                    c.y = 2;
                    c.total_z = (zfm.directories.items.len - zfm.start_pd) + (zfm.files.items.len - zfm.start_pf);
                }
            },
            'D' => {
                if (!std.mem.eql(u8, zfm.path, "/")) {
                    const t_path = std.fs.path.dirname(zfm.path);
                    try zfm.init(t_path.?, term);
                    c.y = 2;
                    c.total_z = (zfm.directories.items.len - zfm.start_pd) + (zfm.files.items.len - zfm.start_pf);
                }
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

    try zfm.populate();
    sort_list(&zfm.files);
    sort_list(&zfm.directories);

    var cursor = Cursor{
        .y = 2,
        .x = 1,
        .total_y = 1,
        .total_z = (zfm.directories.items.len - zfm.start_pd) + (zfm.files.items.len - zfm.start_pf),
    };

    zfm.find_start();
    zfm.get_endp(&term);
    while (!quit) {
        try term.clear();
        cursor.total_y = 1;
        try term.stdout.print("{s}\r\n", .{zfm.path});
        if (try term.term_size()) {
            zfm.get_endp(&term);
        }

        try term.print_files(&zfm, &cursor);

        var chosen: []const u8 = undefined;
        if ((zfm.directories.items.len - zfm.start_pd) > cursor.y - 2) {
            chosen = zfm.directories.items.ptr[cursor.y - 2 + zfm.start_pd];
            term.fg = FG_DIR;
            if (zfm.next_directory(chosen[4..], &cursor, &term)) |zf_next| {
                var zfm2 = zf_next;
                defer zfm2.deinit();
                sort_list(&zfm2.files);
                sort_list(&zfm2.directories);
                if (zfm2.files.items.len == 0 and zfm2.directories.items.len == 0) {
                    zfm.next_empty = true;
                    try term.right_print(&cursor, "EMPTY");
                } else {
                    zfm2.find_start();
                    zfm2.get_endp(&term);
                    try term.print_files(&zfm2, &cursor);
                }
            } else |err| {
                try term.right_print(&cursor, @errorName(err));
                zfm.next_empty = true;
            }
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
        var tmp: usize = chosen.len;
        while (tmp < (term.width / 2)) : (tmp += 1) {
            try term.stdout.print(" ", .{});
        }
        term.fg = FG_DIR;
        try term.stdout.print("\x1b[m", .{});

        try key_pressed(&cursor, &quit, &zfm, &term, chosen[4..]);
        zfm.next_empty = false;
    }
}
