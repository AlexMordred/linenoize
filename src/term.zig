const std = @import("std");
const builtin = @import("builtin");
const File = std.fs.File;

const unsupported_term = [_][]const u8{ "dumb", "cons25", "emacs" };

const is_windows = builtin.os.tag == .windows;
const termios = if (!is_windows) std.posix.termios else struct { inMode: w.DWORD, outMode: w.DWORD };

pub fn isUnsupportedTerm(allocator: std.mem.Allocator) bool {
    const env_var = std.process.getEnvVarOwned(allocator, "TERM") catch return false;
    defer allocator.free(env_var);
    return for (unsupported_term) |t| {
        if (std.ascii.eqlIgnoreCase(env_var, t))
            break true;
    } else false;
}

const w = struct {
    pub usingnamespace std.os.windows;
    pub const ENABLE_VIRTUAL_TERMINAL_INPUT = @as(c_int, 0x200);
    pub const CP_UTF8 = @as(c_int, 65001);
    pub const INPUT_RECORD = extern struct {
        EventType: w.WORD,
        _ignored: [16]u8,
    };
};

const k32 = struct {
    pub usingnamespace std.os.windows.kernel32;
    pub extern "kernel32" fn SetConsoleCP(wCodePageID: w.UINT) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn PeekConsoleInputW(hConsoleInput: w.HANDLE, lpBuffer: [*]w.INPUT_RECORD, nLength: w.DWORD, lpNumberOfEventsRead: ?*w.DWORD) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn ReadConsoleW(hConsoleInput: w.HANDLE, lpBuffer: [*]u16, nNumberOfCharsToRead: w.DWORD, lpNumberOfCharsRead: ?*w.DWORD, lpReserved: ?*anyopaque) callconv(w.WINAPI) w.BOOL;
};

pub fn enableRawMode(in: File, out: File) !termios {
    if (is_windows) {
        var result: termios = .{
            .inMode = 0,
            .outMode = 0,
        };
        var irec: [1]w.INPUT_RECORD = undefined;
        var n: w.DWORD = 0;
        if (k32.PeekConsoleInputW(in.handle, &irec, 1, &n) == 0 or
            k32.GetConsoleMode(in.handle, &result.inMode) == 0 or
            k32.GetConsoleMode(out.handle, &result.outMode) == 0)
            return error.InitFailed;
        _ = k32.SetConsoleMode(in.handle, w.ENABLE_VIRTUAL_TERMINAL_INPUT);
        _ = k32.SetConsoleMode(out.handle, result.outMode | w.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        _ = k32.SetConsoleCP(w.CP_UTF8);
        _ = k32.SetConsoleOutputCP(w.CP_UTF8);
        return result;
    } else {
        const orig = try std.posix.tcgetattr(in.handle);
        var raw = orig;

        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.cflag.CSIZE = .CS8;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // FIXME
        // raw.cc[std.os.VMIN] = 1;
        // raw.cc[std.os.VTIME] = 0;

        try std.posix.tcsetattr(in.handle, std.posix.TCSA.FLUSH, raw);

        return orig;
    }
}

pub fn disableRawMode(in: File, out: File, orig: termios) void {
    if (is_windows) {
        _ = k32.SetConsoleMode(in.handle, orig.inMode);
        _ = k32.SetConsoleMode(out.handle, orig.outMode);
    } else {
        std.posix.tcsetattr(in.handle, std.posix.TCSA.FLUSH, orig) catch {};
    }
}

fn getCursorPosition(in: File, out: File) !usize {
    var buf: [32]u8 = undefined;
    var reader = in.reader();

    // Tell terminal to report cursor to in
    try out.writeAll("\x1B[6n");

    // Read answer
    const answer = (try reader.readUntilDelimiterOrEof(&buf, 'R')) orelse
        return error.CursorPos;

    // Parse answer
    if (!std.mem.startsWith(u8, "\x1B[", answer))
        return error.CursorPos;

    var iter = std.mem.splitScalar(u8, answer[2..], ';');
    _ = iter.next() orelse return error.CursorPos;
    const x = iter.next() orelse return error.CursorPos;

    return try std.fmt.parseInt(usize, x, 10);
}

fn getColumnsFallback(in: File, out: File) !usize {
    var writer = out.writer();
    const orig_cursor_pos = try getCursorPosition(in, out);

    try writer.print("\x1B[999C", .{});
    const cols = try getCursorPosition(in, out);

    try writer.print("\x1B[{}D", .{orig_cursor_pos});

    return cols;
}

pub fn getColumns(in: File, out: File) !usize {
    switch (builtin.os.tag) {
        .windows => {
            var csbi: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            _ = k32.GetConsoleScreenBufferInfo(out.handle, &csbi);
            return @intCast(csbi.dwSize.X);
        },
        else => {
            var winsize: std.posix.winsize = .{
                .row = 0,
                .col = 0,
                .xpixel = 0,
                .ypixel = 0,
            };

            const err = std.posix.system.ioctl(in.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
            if (std.posix.errno(err) == .SUCCESS and winsize.col > 0) {
                return winsize.col;
            } else {
                return try getColumnsFallback(in, out);
            }
        },
    }
}

pub fn clearScreen() !void {
    const stdout = std.io.getStdErr();
    try stdout.writeAll("\x1b[H\x1b[2J");
}

pub fn beep() !void {
    const stderr = std.io.getStdErr();
    try stderr.writeAll("\x07");
}

var utf8ConsoleBuffer = [_]u8{0} ** 10;
var utf8ConsoleReadBytes: usize = 0;

// this is needed due to a bug in win32 console: https://github.com/microsoft/terminal/issues/4551
fn readWin32Console(self: File, buffer: []u8) !usize {
    var toRead = buffer.len;
    while (toRead > 0) {
        if (utf8ConsoleReadBytes > 0) {
            const existing = @min(toRead, utf8ConsoleReadBytes);
            @memcpy(buffer[(buffer.len - toRead)..], utf8ConsoleBuffer[0..existing]);
            utf8ConsoleReadBytes -= existing;
            if (utf8ConsoleReadBytes > 0)
                std.mem.copyForwards(u8, &utf8ConsoleBuffer, utf8ConsoleBuffer[existing..]);
            toRead -= existing;
            continue;
        }
        var charsRead: w.DWORD = 0;
        var wideBuf: [2]w.WCHAR = undefined;
        if (k32.ReadConsoleW(self.handle, &wideBuf, 1, &charsRead, null) == 0)
            return 0;
        if (charsRead == 0)
            break;
        const wideBufLen: u8 = if (wideBuf[0] >= 0xD800 and wideBuf[0] <= 0xDBFF) _: {
            // read surrogate
            if (k32.ReadConsoleW(self.handle, wideBuf[1..], 1, &charsRead, null) == 0)
                return 0;
            if (charsRead == 0)
                break;
            break :_ 2;
        } else 1;
        //WideCharToMultiByte(GetConsoleCP(), 0, buf, bufLen, converted, sizeof(converted), NULL, NULL);
        utf8ConsoleReadBytes += try std.unicode.utf16LeToUtf8(&utf8ConsoleBuffer, wideBuf[0..wideBufLen]);
    }
    return buffer.len - toRead;
}

pub const read = if (is_windows) readWin32Console else File.read;
