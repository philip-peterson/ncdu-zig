pub const program_version = "2.0-dev";

const std = @import("std");
const model = @import("model.zig");
const scan = @import("scan.zig");
const ui = @import("ui.zig");
const browser = @import("browser.zig");
const c = @cImport(@cInclude("locale.h"));

pub const allocator = std.heap.c_allocator;

pub const SortCol = enum { name, blocks, size, items, mtime };
pub const SortOrder = enum { asc, desc };

pub const Config = struct {
    same_fs: bool = true,
    extended: bool = false,
    follow_symlinks: bool = false,
    exclude_caches: bool = false,
    exclude_kernfs: bool = false,
    exclude_patterns: std.ArrayList([:0]const u8) = std.ArrayList([:0]const u8).init(allocator),

    update_delay: u64 = 100*std.time.ns_per_ms,
    scan_ui: enum { none, line, full } = .full,
    si: bool = false,
    nc_tty: bool = false,
    ui_color: enum { off, dark } = .off,
    thousands_sep: []const u8 = ".",

    show_hidden: bool = true,
    show_blocks: bool = true,
    show_items: bool = false,
    show_mtime: bool = false,
    show_graph: enum { off, graph, percent, both } = .graph,
    sort_col: SortCol = .blocks,
    sort_order: SortOrder = .desc,
    sort_dirsfirst: bool = false,

    read_only: bool = false,
    can_shell: bool = true,
    confirm_quit: bool = false,
};

pub var config = Config{};

pub var state: enum { scan, browse } = .browse;

// Simple generic argument parser, supports getopt_long() style arguments.
// T can be any type that has a 'fn next(T) ?[:0]const u8' method, e.g.:
//   var args = Args(std.process.ArgIteratorPosix).init(std.process.ArgIteratorPosix.init());
fn Args(T: anytype) type {
    return struct {
        it: T,
        short: ?[:0]const u8 = null, // Remainder after a short option, e.g. -x<stuff> (which may be either more short options or an argument)
        last: ?[]const u8 = null,
        last_arg: ?[:0]const u8 = null, // In the case of --option=<arg>
        shortbuf: [2]u8 = undefined,
        argsep: bool = false,

        const Self = @This();
        const Option = struct {
            opt: bool,
            val: []const u8,

            fn is(self: @This(), cmp: []const u8) bool {
                return self.opt and std.mem.eql(u8, self.val, cmp);
            }
        };

        fn init(it: T) Self {
            return Self{ .it = it };
        }

        fn shortopt(self: *Self, s: [:0]const u8) Option {
            self.shortbuf[0] = '-';
            self.shortbuf[1] = s[0];
            self.short = if (s.len > 1) s[1.. :0] else null;
            self.last = &self.shortbuf;
            return .{ .opt = true, .val = &self.shortbuf };
        }

        /// Return the next option or positional argument.
        /// 'opt' indicates whether it's an option or positional argument,
        /// 'val' will be either -x, --something or the argument.
        pub fn next(self: *Self) ?Option {
            if (self.last_arg != null) ui.die("Option '{s}' does not expect an argument.\n", .{ self.last.? });
            if (self.short) |s| return self.shortopt(s);
            const val = self.it.next() orelse return null;
            if (self.argsep or val.len == 0 or val[0] != '-') return Option{ .opt = false, .val = val };
            if (val.len == 1) ui.die("Invalid option '-'.\n", .{});
            if (val.len == 2 and val[1] == '-') {
                self.argsep = true;
                return self.next();
            }
            if (val[1] == '-') {
                if (std.mem.indexOfScalar(u8, val, '=')) |sep| {
                    if (sep == 2) ui.die("Invalid option '{s}'.\n", .{val});
                    self.last_arg = val[sep+1.. :0];
                    self.last = val[0..sep];
                    return Option{ .opt = true, .val = self.last.? };
                }
                self.last = val;
                return Option{ .opt = true, .val = val };
            }
            return self.shortopt(val[1..:0]);
        }

        /// Returns the argument given to the last returned option. Dies with an error if no argument is provided.
        pub fn arg(self: *Self) [:0]const u8 {
            if (self.short) |a| {
                defer self.short = null;
                return a;
            }
            if (self.last_arg) |a| {
                defer self.last_arg = null;
                return a;
            }
            if (self.it.next()) |o| return o;
            ui.die("Option '{s}' requires an argument.\n", .{ self.last.? });
        }
    };
}

fn version() noreturn {
    std.io.getStdOut().writer().writeAll("ncdu " ++ program_version ++ "\n") catch {};
    std.process.exit(0);
}

fn help() noreturn {
    std.io.getStdOut().writer().writeAll(
        "ncdu <options> <directory>\n\n"
     ++ "  -h,--help                  This help message\n"
     ++ "  -q                         Quiet mode, refresh interval 2 seconds\n"
     ++ "  -v,-V,--version            Print version\n"
     ++ "  -x                         Same filesystem\n"
     ++ "  -e                         Enable extended information\n"
     ++ "  -r                         Read only\n"
     ++ "  -o FILE                    Export scanned directory to FILE\n"
     ++ "  -f FILE                    Import scanned directory from FILE\n"
     ++ "  -0,-1,-2                   UI to use when scanning (0=none,2=full ncurses)\n"
     ++ "  --si                       Use base 10 (SI) prefixes instead of base 2\n"
     ++ "  --exclude PATTERN          Exclude files that match PATTERN\n"
     ++ "  -X, --exclude-from FILE    Exclude files that match any pattern in FILE\n"
     ++ "  -L, --follow-symlinks      Follow symbolic links (excluding directories)\n"
     ++ "  --exclude-caches           Exclude directories containing CACHEDIR.TAG\n"
     ++ "  --exclude-kernfs           Exclude Linux pseudo filesystems (procfs,sysfs,cgroup,...)\n"
     ++ "  --confirm-quit             Confirm quitting ncdu\n"
     ++ "  --color SCHEME             Set color scheme (off/dark)\n"
    ) catch {};
    std.process.exit(0);
}

fn readExcludeFile(path: []const u8) !void {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var rd = std.io.bufferedReader(f.reader()).reader();
    var buf = std.ArrayList(u8).init(allocator);
    while (true) {
        rd.readUntilDelimiterArrayList(&buf, '\n', 4096)
            catch |e| if (e != error.EndOfStream) return e else if (buf.items.len == 0) break;
        if (buf.items.len > 0)
            try config.exclude_patterns.append(try buf.toOwnedSliceSentinel(0));
    }
}

// TODO: Better error reporting
pub fn main() !void {
    // Grab thousands_sep from the current C locale.
    // (We can safely remove this when not linking against libc, it's a somewhat obscure feature)
    _ = c.setlocale(c.LC_ALL, "");
    if (c.localeconv()) |locale| {
        if (locale.*.thousands_sep) |sep| {
            const span = std.mem.spanZ(sep);
            if (span.len > 0)
                config.thousands_sep = span;
        }
    }

    var args = Args(std.process.ArgIteratorPosix).init(std.process.ArgIteratorPosix.init());
    var scan_dir: ?[]const u8 = null;
    var import_file: ?[]const u8 = null;
    var export_file: ?[]const u8 = null;
    var has_scan_ui = false;
    _ = args.next(); // program name
    while (args.next()) |opt| {
        if (!opt.opt) {
            // XXX: ncdu 1.x doesn't error, it just silently ignores all but the last argument.
            if (scan_dir != null) ui.die("Multiple directories given, see ncdu -h for help.\n", .{});
            scan_dir = opt.val;
            continue;
        }
        if (opt.is("-h") or opt.is("-?") or opt.is("--help")) help()
        else if(opt.is("-v") or opt.is("-V") or opt.is("--version")) version()
        else if(opt.is("-q")) config.update_delay = 2*std.time.ns_per_s
        else if(opt.is("-x")) config.same_fs = true
        else if(opt.is("-e")) config.extended = true
        else if(opt.is("-r") and config.read_only) config.can_shell = false
        else if(opt.is("-r")) config.read_only = true
        else if(opt.is("-0")) { has_scan_ui = true; config.scan_ui = .none; }
        else if(opt.is("-1")) { has_scan_ui = true; config.scan_ui = .line; }
        else if(opt.is("-2")) { has_scan_ui = true; config.scan_ui = .full; }
        else if(opt.is("-o")) export_file = args.arg()
        else if(opt.is("-f")) import_file = args.arg()
        else if(opt.is("--si")) config.si = true
        else if(opt.is("-L") or opt.is("--follow-symlinks")) config.follow_symlinks = true
        else if(opt.is("--exclude")) try config.exclude_patterns.append(args.arg())
        else if(opt.is("-X") or opt.is("--exclude-from")) {
            const arg = args.arg();
            readExcludeFile(arg) catch |e| ui.die("Error reading excludes from {s}: {}.\n", .{ arg, e });
        } else if(opt.is("--exclude-caches")) config.exclude_caches = true
        else if(opt.is("--exclude-kernfs")) config.exclude_kernfs = true
        else if(opt.is("--confirm-quit")) config.confirm_quit = true
        else if(opt.is("--color")) {
            const val = args.arg();
            if (std.mem.eql(u8, val, "off")) config.ui_color = .off
            else if (std.mem.eql(u8, val, "dark")) config.ui_color = .dark
            else ui.die("Unknown --color option: {s}.\n", .{val});
        } else ui.die("Unrecognized option '{s}'.\n", .{opt.val});
    }

    if (std.builtin.os.tag != .linux and config.exclude_kernfs)
        ui.die("The --exclude-kernfs tag is currently only supported on Linux.\n", .{});

    const out_tty = std.io.getStdOut().isTty();
    if (!has_scan_ui) {
        if (export_file) |f| {
            if (!out_tty or std.mem.eql(u8, f, "-")) config.scan_ui = .none
            else config.scan_ui = .line;
        }
    }
    config.nc_tty = if (export_file) |f| std.mem.eql(u8, f, "-") else false;

    event_delay_timer = try std.time.Timer.start();
    defer ui.deinit();

    var out_file = if (export_file) |f| (
        if (std.mem.eql(u8, f, "-")) std.io.getStdOut()
        else try std.fs.cwd().createFile(f, .{})
    ) else null;

    state = .scan;
    try scan.scanRoot(scan_dir orelse ".", out_file);
    if (out_file != null) return;

    config.scan_ui = .full; // in case we're refreshing from the UI, always in full mode.
    ui.init();
    state = .browse;
    try browser.loadDir();

    // TODO: Handle OOM errors
    while (true) try handleEvent(true, false);
}

var event_delay_timer: std.time.Timer = undefined;

// Draw the screen and handle the next input event.
// In non-blocking mode, screen drawing is rate-limited to keep this function fast.
pub fn handleEvent(block: bool, force_draw: bool) !void {
    if (block or force_draw or event_delay_timer.read() > config.update_delay) {
        if (ui.inited) _ = ui.c.erase();
        switch (state) {
            .scan => try scan.draw(),
            .browse => try browser.draw(),
        }
        if (ui.inited) _ = ui.c.refresh();
        event_delay_timer.reset();
    }
    if (!ui.inited) {
        std.debug.assert(!block);
        return;
    }

    var firstblock = block;
    while (true) {
        var ch = ui.getch(firstblock);
        if (ch == 0) return;
        if (ch == -1) return handleEvent(firstblock, true);
        switch (state) {
            .scan => try scan.key(ch),
            .browse => try browser.key(ch),
        }
        firstblock = false;
    }
}


test "argument parser" {
    const L = struct {
        lst: []const [:0]const u8,
        idx: usize = 0,
        fn next(s: *@This()) ?[:0]const u8 {
            if (s.idx == s.lst.len) return null;
            defer s.idx += 1;
            return s.lst[s.idx];
        }
    };
    const lst = [_][:0]const u8{ "a", "-abcd=e", "--opt1=arg1", "--opt2", "arg2", "-x", "foo", "", "--", "--arg", "", "-", };
    const l = L{ .lst = &lst };
    const T = struct {
        a: Args(L),
        fn opt(self: *@This(), isopt: bool, val: []const u8) void {
            const o = self.a.next().?;
            std.testing.expectEqual(isopt, o.opt);
            std.testing.expectEqualStrings(val, o.val);
            std.testing.expectEqual(o.is(val), isopt);
        }
        fn arg(self: *@This(), val: []const u8) void {
            std.testing.expectEqualStrings(val, self.a.arg());
        }
    };
    var t = T{ .a = Args(L).init(l) };
    t.opt(false, "a");
    t.opt(true, "-a");
    t.opt(true, "-b");
    t.arg("cd=e");
    t.opt(true, "--opt1");
    t.arg("arg1");
    t.opt(true, "--opt2");
    t.arg("arg2");
    t.opt(true, "-x");
    t.arg("foo");
    t.opt(false, "");
    t.opt(false, "--arg");
    t.opt(false, "");
    t.opt(false, "-");
    std.testing.expectEqual(t.a.next(), null);
}
