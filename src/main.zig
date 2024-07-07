const std = @import("std");
const system = std.os.linux;
const fs = std.fs;
const path = fs.path;
const FileIcon = "";
const DirIcon = "";
const FG_FILES = 32;
const FG_DIR = 34;

var hidden: bool = false;
var scheduled_mode = false;

//var sorted: bool = false;

// TODO:
// Add functionality from enum
// Add config file
// add the time of the creation
// add visual mode

const Key = enum {
    UP,
    DOWN,
    RIGHT,
    LEFT,
    HIDE,
    QUIT,
    DELETE,
    UNDO,
    RESTART,
    RENAME,
    MOVE,
    COPY,
    PASTE,
    GOTO_END,
    GOTO_START,
    NEW_FILE,
    NEW_DIR,
    NOT_IMPLEMENTED,
};

const Cursor = struct {
    y: u16,
    x: u16,
};

pub fn copy_fn(a: []const u8, b: []const u8) anyerror!void {
    try fs.copyFileAbsolute(a, b, .{});
    //
}

const ScheduledType = struct {
    ptr: union(enum) {
        one: *const fn ([]const u8) anyerror!void,
        two: *const fn ([]const u8, []const u8) anyerror!void,
    },
    arg: union(enum) {
        one: []const u8,
        two: struct { a: []const u8, b: []const u8 },
    },
};

const Scheduled = struct {
    scheduled: std.ArrayList(ScheduledType),

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Scheduled {
        return Scheduled{
            .scheduled = std.ArrayList(ScheduledType).init(alloc),
        };
    }

    pub fn free_items(self: *Self) void {
        for (self.scheduled.items) |item| {
            switch (item.arg) {
                .one => |arg1| self.scheduled.allocator.free(arg1),
                .two => |args| {
                    self.scheduled.allocator.free(args.a);
                    self.scheduled.allocator.free(args.b);
                },
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.free_items();
        self.scheduled.deinit();
    }
    pub fn run(self: *Self) !void {
        for (self.scheduled.items) |func| {
            switch (func.ptr) {
                .one => |f| {
                    switch (func.arg) {
                        .one => |arg| try f(arg),
                        .two => @panic("Mismatch ptr and arg"),
                    }
                },
                .two => |f| {
                    switch (func.arg) {
                        .one => @panic("Mismatch ptr and arg"),
                        .two => |args| {
                            try f(args.a, args.b);
                        },
                    }
                },
            }
        }
    }
    pub fn restart(self: *Self, alloc: std.mem.Allocator) !void {
        try self.run();
        self.deinit();
        self.* = Scheduled.init(alloc);
    }
};

const FileItems = struct {
    icon: []const u8,
    name: []const u8,
    kind: fs.File.Kind,
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
    pub fn input_mode(self: *Self, msg: []const u8, alloc: std.mem.Allocator, name: []const u8) ![]u8 {
        const stdin = std.io.getStdIn().reader();

        try self.stdout.print("\x1b[{d};{d}H", .{ self.height, 0 });
        for (0..self.width) |i| {
            _ = i;
            try self.stdout.print(" ", .{});
        }
        try self.stdout.print("\x1b[{d};{d}H{s} {s}: ", .{ self.height, 0, msg, name });
        try self.disable_raw();
        try self.show_cursor();

        if (stdin.readUntilDelimiterAlloc(alloc, '\n', 256)) |result| {
            std.debug.print("from func: {s}\n", .{result});
            try self.enable_raw();
            try self.hide_cursor();
            return result;
        } else |err| {
            std.debug.print("from func err\n", .{});
            try self.enable_raw();
            try self.hide_cursor();
            return err;
        }
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
    fn print_entries(self: *Self, zfm: *Zfm, x: u16) !void {
        var k: usize = 0;

        const entries = zfm.entries.items[zfm.start_e..];
        var total_y: u16 = 1;
        for (entries) |item| {
            if (item.name[0] == '.' and hidden == true)
                continue;
            self.fg = if (item.kind == .file) FG_FILES else FG_DIR;
            total_y += 1;
            if (total_y > self.height - 1) break;
            const itemp = try std.mem.concat(zfm.allocator, u8, &[_][]const u8{ item.icon, " ", item.name });
            k = @min(itemp.len, (self.width / 2));
            try self.stdout.print("\x1b[1;{d};{d}m", .{ self.fg, self.bg });
            try self.stdout.print("\x1b[{d};{d}H{s}", .{ total_y, x, itemp[0..k] });
            zfm.allocator.free(itemp);
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

var max_bp: [fs.MAX_PATH_BYTES]u8 = undefined;

pub const Zfm = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(FileItems) = undefined,
    path: []const u8,
    start_e: usize = 0,
    selected: usize = 0,
    next_empty: bool = false,
    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, zpath: []const u8) !Zfm {
        return Zfm{
            .allocator = allocator,
            .entries = std.ArrayList(FileItems).init(allocator),
            .path = try fs.realpath(zpath, &max_bp),
        };
    }

    pub fn init_new(self: *Self, zpath: []const u8) !void {
        self.deinit();
        self.* = try Zfm.create(self.allocator, zpath);
        try self.populate();
        self.selected = 0;
        self.start_e = 0;
        if (hidden) self.inc_selected();
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
        var dir = try fs.openDirAbsolute(self.path, .{ .iterate = true });
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

    pub fn copy_dir(self: *Self, src: []const u8, dest: []const u8) !void {
        var src_dir = try fs.openDirAbsolute(src, .{ .iterate = true });
        defer src_dir.close();
        try fs.makeDirAbsolute(dest);

        var iter = src_dir.iterate();
        while (try iter.next()) |entry| {
            const src_sub_path = try path.join(self.allocator, &.{ src, entry.name });
            defer self.allocator.free(src_sub_path);
            const dest_sub_path = try path.join(self.allocator, &.{ dest, entry.name });
            defer self.allocator.free(dest_sub_path);
            switch (entry.kind) {
                .file => try copy_fn(src_sub_path, dest_sub_path),
                .directory => try self.copy_dir(src_sub_path, dest_sub_path),
                else => {},
            }
        }
    }

    pub fn next_directory(self: *Self, chosen: []const u8) !Zfm {
        const temp = try path.join(self.allocator, &.{ self.path, chosen });
        defer self.allocator.free(temp);

        var zf_next = try Zfm.create(self.allocator, temp);
        try zf_next.populate();
        //try term.print_files(&zf_next, mode, cursor);
        return zf_next;
    }
    pub fn inc_selected(self: *Self) void {
        if (hidden) {
            while (self.entries.items[self.selected].name[0] == '.') {
                if (self.selected < self.entries.items.len - 1) self.selected += 1 else break;
            }
        }
    }
    pub fn dec_selected(self: *Self) void {
        if (hidden) {
            while (self.entries.items[self.selected].name[0] == '.') {
                if (self.selected > 0) self.selected -= 1 else break;
            }
        }
    }
    pub fn count_hidden(self: *Self, from: usize, to: usize) usize {
        var count: usize = 0;
        for (self.entries.items[from..to]) |item| {
            if (item.name[0] == '.') count += 1;
        }
        return count;
    }
};

//temp
pub fn key_pressed() !Key {
    const stdin = std.io.getStdIn().reader();
    var buf: [4]u8 = undefined;
    const prev_buf = struct {
        var value: u8 = 0;
        var counter: u8 = 0;
    };
    const nread = try stdin.read(&buf);
    std.debug.assert(nread >= 0);

    var ret: Key = .NOT_IMPLEMENTED;
    if (nread == 1) {
        switch (buf[0]) {
            0x1b => prev_buf.value = 0,
            'f' => {
                if (prev_buf.value == 'd') ret = .DELETE;
                if (prev_buf.value == 'c') ret = .NEW_FILE;
            },
            'g' => {
                if (prev_buf.value == 'g') ret = .GOTO_START;
            },
            'q', 'q' & 0x1f => ret = .QUIT, //quit.* = true,
            ('h' | 'H') & 0x1f => {
                ret = .HIDE;
            },
            'd' => {
                if (prev_buf.value == 'c') ret = .NEW_DIR;
            },
            'G' => ret = .GOTO_END,
            'u' => ret = .UNDO,
            'x' => ret = .DELETE,
            'e', 'r' & 0x1f => ret = .RESTART,
            'y', ('c' | 'C') & 0x1f => ret = .COPY,
            'p', ('v' | 'V') & 0x1f => ret = .PASTE,
            'h', 'H' => ret = .LEFT,
            'j', 'J' => ret = .DOWN,
            'k', 'K' => ret = .UP,
            'l', 'L' => ret = .RIGHT,
            'R' => ret = .RENAME,
            else => ret = .NOT_IMPLEMENTED,
        }
    }
    prev_buf.value = buf[0];

    if (nread > 2 and buf[0] == '\x1b' and buf[1] == '[') {
        prev_buf.value = 0;
        switch (buf[2]) {
            'A' => ret = .UP,
            'B' => ret = .DOWN,
            'C' => ret = .RIGHT,
            'D' => ret = .LEFT,
            else => ret = .NOT_IMPLEMENTED,
        }
    }
    //3 27 79 81 170
    const f2: [4]u8 = [_]u8{ 27, 79, 81, 170 };
    if (nread > 2 and std.mem.eql(u8, &buf, &f2)) {
        ret = .RENAME;
        prev_buf.value = 0;
    }
    if (ret != .NOT_IMPLEMENTED) prev_buf.counter += 1;
    if (prev_buf.counter > 1) {
        prev_buf.value = 0;
        prev_buf.counter = 0;
    }
    return ret;
}

pub fn handle_keypress(key: Key, zfm: *Zfm, c: *Cursor, t: *Term, chosen: []const u8, s: *Scheduled) !bool {
    const cp = struct {
        var name: ?[]const u8 = null;
        var kind: ?fs.File.Kind = null;
    };
    switch (key) {
        .LEFT => {
            if (!std.mem.eql(u8, zfm.path, "/")) {
                const t_path = path.dirname(zfm.path);
                try zfm.init_new(t_path.?);
                c.y = 2;
            }
        },
        .RIGHT => {
            if (zfm.entries.items[zfm.selected].kind != .file and !zfm.next_empty) {
                const t_path = try path.join(zfm.allocator, &.{ zfm.path, chosen });
                defer zfm.allocator.free(t_path);
                try zfm.init_new(t_path);
                c.y = 2;
            }
        },
        .UP => {
            if (c.y <= t.height / 4 and zfm.start_e > 0) {
                zfm.start_e -= 1;
                c.y = t.height / 4;
                if (zfm.selected > 0) zfm.selected -= 1;
                zfm.dec_selected();
            } else if (c.y > 2) {
                c.y -= 1;
                if (zfm.selected > 0) zfm.selected -= 1;
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
                if (zfm.selected < zfm.entries.items.len - 1) zfm.selected += 1;
                zfm.inc_selected();
            } else if (c.y < __min and zfm.selected < zfm.entries.items.len - 1) {
                c.y += 1;
                zfm.selected += 1;
                zfm.inc_selected();
            }
        },
        .PASTE => {
            const basename = path.basename(cp.name.?);
            const dest_path = try path.join(zfm.allocator, &.{ zfm.path, basename });
            if (cp.kind) |kind| {
                switch (kind) {
                    .directory => try zfm.copy_dir(cp.name.?, dest_path),
                    .file => try copy_fn(cp.name.?, dest_path),
                    else => {},
                }
                c.y = 2;
                try zfm.init_new(zfm.path);
                zfm.allocator.free(dest_path);
                zfm.allocator.free(cp.name.?);
                cp.name = null;
                cp.kind = null;
            }
        },
        .MOVE => {},
        .COPY => {
            const sel = zfm.entries.items[zfm.selected].name;
            cp.kind = zfm.entries.items[zfm.selected].kind;
            if (cp.name != null) {
                zfm.allocator.free(cp.name.?);
                cp.name = null;
            }
            cp.name = try path.join(zfm.allocator, &.{ zfm.path, sel });
        },
        .GOTO_START => {
            c.y = 2;
            zfm.start_e = 0;
            zfm.selected = 0;
            if (hidden) zfm.inc_selected();
        },
        .RESTART => {
            try s.restart(zfm.allocator);
            c.y = 2;
            try zfm.init_new(zfm.path);
        },
        .GOTO_END => {
            zfm.selected = zfm.entries.items.len - 1;
            var cy: usize = 0;
            if (hidden) {
                if (zfm.entries.items[zfm.selected].name[0] == '.')
                    zfm.dec_selected();
                cy = zfm.count_hidden(0, zfm.entries.items.len);
            }
            zfm.start_e = if (zfm.selected - cy > t.height) zfm.selected - (t.height - 3) else 0;
            c.y = @min((t.height - 1), (zfm.selected - cy + 2));
        },
        .DELETE => {
            const sel = zfm.entries.items[zfm.selected].name;
            const fullpath = try path.join(zfm.allocator, &.{ zfm.path, sel });
            try s.scheduled.append(.{
                .arg = .{ .one = try zfm.allocator.dupe(u8, fullpath) },
                .ptr = .{ .one = &fs.deleteTreeAbsolute },
            });
            var prev_sel = zfm.selected;
            if (prev_sel == zfm.entries.items.len - 1) {
                if (c.y > 2) c.y -= 1;
                if (prev_sel > 0) prev_sel -= 1;
            }
            if (!scheduled_mode) {
                try s.restart(zfm.allocator);
                try zfm.init_new(zfm.path);
            } else {
                const deleted = zfm.entries.swapRemove(zfm.selected);
                zfm.allocator.free(deleted.name);
                zfm.allocator.free(deleted.icon);
            }
            zfm.selected = prev_sel;
            zfm.allocator.free(fullpath);
        },
        .UNDO => { //this is only temporary it doesnt even work
            if (s.scheduled.items.len > 0) {
                const last = s.scheduled.pop();
                switch (last.arg) {
                    .one => |arg| zfm.allocator.free(arg),
                    .two => |args| {
                        zfm.allocator.free(args.a);
                        zfm.allocator.free(args.b);
                    },
                }
            }
        },
        .NEW_FILE => {
            const input_result = try t.input_mode("New File in", zfm.allocator, zfm.path);
            defer zfm.allocator.free(input_result);
            const zpath = try path.join(zfm.allocator, &.{ zfm.path, input_result });
            const file = try fs.createFileAbsolute(zpath, .{ .read = true });
            defer file.close();
            if (zfm.entries.items.len > 0) {
                const prev_sel_name = try zfm.allocator.dupe(u8, zfm.entries.items[zfm.selected].name);
                try zfm.init_new(zfm.path);
                for (zfm.entries.items, 0..) |item, index| {
                    if (std.mem.eql(u8, prev_sel_name, item.name)) {
                        zfm.selected = index;
                        c.y = @min(index + 2, t.height - 1);
                        break;
                    }
                }
                zfm.allocator.free(prev_sel_name);
            } else try zfm.init_new(zfm.path);
            zfm.allocator.free(zpath);
        },
        .NEW_DIR => {
            const input_result = try t.input_mode("New directory in", zfm.allocator, zfm.path);
            defer zfm.allocator.free(input_result);
            const zpath = try path.join(zfm.allocator, &.{ zfm.path, input_result });
            defer zfm.allocator.free(zpath);
            try fs.makeDirAbsolute(zpath);
            if (zfm.entries.items.len > 0) {
                const prev_sel_name = try zfm.allocator.dupe(u8, zfm.entries.items[zfm.selected].name);
                try zfm.init_new(zfm.path);
                for (zfm.entries.items, 0..) |item, index| {
                    if (std.mem.eql(u8, prev_sel_name, item.name)) {
                        zfm.selected = index;
                        c.y = @min(index + 2, t.height - 1);
                        break;
                    }
                }
                zfm.allocator.free(prev_sel_name);
            } else try zfm.init_new(zfm.path);
        },
        .RENAME => {
            const sel = zfm.entries.items[zfm.selected].name;
            const input_result = try t.input_mode("New name for", zfm.allocator, sel);
            defer zfm.allocator.free(input_result);
            const old_path = try path.join(zfm.allocator, &.{ zfm.path, sel });
            const new_path = try path.join(zfm.allocator, &.{ zfm.path, input_result });

            try fs.renameAbsolute(old_path, new_path);
            try zfm.init_new(zfm.path);
            c.y = 2;
            zfm.selected = 0;
            zfm.allocator.free(old_path);
            zfm.allocator.free(new_path);
        },
        .HIDE => {
            hidden = !hidden;
            var cc: u16 = 0;
            if (hidden) {
                if (zfm.entries.items[zfm.selected].name[0] == '.')
                    zfm.inc_selected();
                if (std.math.cast(u16, zfm.count_hidden(zfm.start_e, zfm.selected))) |count| {
                    cc = count;
                } else {
                    cc = 0;
                }
                c.y = @min(zfm.selected - cc + 2, t.height - 1);
            } else {
                c.y = @min(zfm.selected + 2, t.height - 1);
            }
            //c.y = 2;
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

pub fn main() !void {
    var quit = false;

    const arg_path: []const u8 =
        if (std.os.argv.len > 1) std.mem.span(@as([*:0]const u8, std.os.argv.ptr[1])) else ".";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var s = Scheduled.init(gpa.allocator());

    var zfm = try Zfm.create(gpa.allocator(), arg_path);
    defer zfm.deinit();

    var term = Term{ .og_termios = undefined };
    try term.init();
    defer term.deinit() catch {};

    var cursor = Cursor{
        .y = 2,
        .x = 1,
    };

    try zfm.populate();
    var sel_size: u64 = 0;

    while (!quit) {
        try term.clear();
        try term.term_size();
        try term.stdout.print("{s}\r\n", .{zfm.path});
        if (zfm.entries.items.len == 0) {
            try term.stdout.print("\x1b[{d};{d}H<EMPTY>", .{ 2, 1 });
            const key: Key = try key_pressed();
            if (key != .QUIT and key != .LEFT and key != .NEW_FILE and key != .NEW_DIR) continue;
            quit = try handle_keypress(key, &zfm, &cursor, &term, "", &s);
            zfm.next_empty = false;
            continue;
        }
        try term.print_entries(&zfm, cursor.x);

        const chosen: []const u8 = zfm.entries.items[zfm.selected].name;

        if (zfm.entries.items[zfm.selected].kind == .directory) {
            if (zfm.next_directory(chosen)) |zf_next| {
                var zfm2 = zf_next;
                defer zfm2.deinit();
                const fullpath = try path.join(gpa.allocator(), &.{ zfm.path, chosen });
                defer gpa.allocator().free(fullpath);
                var dirsel = try fs.cwd().openDir(fullpath, .{});
                defer dirsel.close();
                const md = try dirsel.metadata();
                sel_size = md.size();
                if (zfm2.entries.items.len == 0) {
                    try term.right_print("EMPTY");
                } else {
                    try term.print_entries(&zfm2, term.width / 2);
                }
            } else |err| {
                try term.right_print(@errorName(err));
                zfm.next_empty = true;
            }
        } else {
            term.fg = FG_FILES;
            const fullpath = try path.join(gpa.allocator(), &.{ zfm.path, chosen });
            defer gpa.allocator().free(fullpath);
            var fil = try fs.cwd().openFile(fullpath, .{});
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
                var total_y: u16 = 2;

                const writer = line.writer();
                while (reader.streamUntilDelimiter(writer, '\n', null)) : (total_y += 1) {
                    defer line.clearRetainingCapacity();
                    if (total_y > term.height - 1) break;
                    const k = @min(line.items.len, term.width - cursor.x);

                    try term.stdout.print("\x1b[m", .{});
                    try term.stdout.print("\x1b[{d};{d}H", .{ total_y, cursor.x });
                    try term.stdout.print("{s}\r\n", .{line.items.ptr[0..k]});
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => return err,
                }
            }
        }

        const icon = zfm.entries.items[zfm.selected].icon;
        const selected =
            try std.mem.concat(gpa.allocator(), u8, &[_][]const u8{ icon, " ", chosen });

        cursor.x = 1;
        const fmt_bytes = try format_bytes(sel_size, gpa.allocator());
        try term.print_selected(&cursor, selected, fmt_bytes);
        gpa.allocator().free(selected);
        gpa.allocator().free(fmt_bytes);

        term.fg = FG_DIR;
        try term.stdout.print("\x1b[m", .{});

        const key: Key = try key_pressed();
        quit = try handle_keypress(key, &zfm, &cursor, &term, chosen, &s);
        zfm.next_empty = false;
    }
    s.run() catch |err| {
        std.debug.print("Error: {}\n", .{err});
    };
    s.deinit();
}
