//! Zorth is a [threaded](https://en.wikipedia.org/wiki/Threaded_code)
//! [Forth](https://en.wikipedia.org/wiki/Forth_(programming_language)) in
//! Zig.  It is based on [jonesforth](https://rwmj.wordpress.com/tag/jonesforth/)
//! which you should definitely check out.
//!
//! Jonesforth leans heavily on [indirect jumps](https://en.wikipedia.org/wiki/Indirect_branch)
//! as is natural in assembly.  The closest Zig analog would be
//! [labeled continue](https://github.com/ziglang/zig/issues/8220). Unfortunately,
//! that requires sticking all the code in one giant `switch` statement, à la
//! `ceval.c` in cpython.  Fortunately, Zig provides an alternative that lets us
//! write cleaner code: `.always_tail`.  Instead of switch prongs, built-in Forth
//! words map to Zig functions which are only ever tail called.
const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const os = std.os;
const syscalls = os.linux.syscalls;
const testing = std.testing;
const builtin = @import("builtin");
const arch = builtin.cpu.arch;
const native = arch.endian();

const conv: std.builtin.CallingConvention = switch (arch) {
    .x86_64 => .winapi,
    else => .auto,
};

const O_RDONLY = 0o0;
const O_WRONLY = 0o1;
const O_RDWR = 0o2;
const O_CREAT = 0o100;
const O_EXCL = 0o200;
const O_TRUNC = 0o1_000;
const O_APPEND = 0o2_000;
const O_NONBLOCK = 0o4_000;
const F_LENMASK = std.ascii.control_code.us;
const Flag = enum(u8) { IMMED = 0x80, HIDDEN = ' ', ZERO = 0x0 };

// https://matklad.github.io/2025/12/23/zig-newtypes-index-pattern.html
const Word = enum(u32) {
    _,

    /// The layout of this `struct` is very important for introspection to work.
    /// Ideally, we would use [flexible array members](https://en.wikipedia.org/wiki/Flexible_array_member)
    /// but I'm not sure how they work in Zig.  So I lie a little and `Word` only
    /// represents metadata.  "Real" words are arrays of `Address` whose first
    /// `offset` elements are disgustingly `@ptrCast`ed to a `Word` when
    /// necessary.  Ugh.
    pub const Data = extern struct {
        link: Address,
        flag: u8,
        name: [F_LENMASK]u8 align(1),
        code: Word,
    };
};

inline fn codeFieldAddress(w: Address) usize {
    return @intFromEnum(w) + @offsetOf(Word.Data, "code");
}

inline fn openFlags(flags: usize) std.c.O {
    return switch (builtin.os.tag) {
        .linux, .macos, .emscripten => .{
            // O_RDWR (2) alone only covers bit 1; RDONLY/WRONLY/RDWR need
            // both access-mode bits (0 and 1), i.e. O_WRONLY | O_RDWR (3).
            .ACCMODE = @enumFromInt(flags & (O_WRONLY | O_RDWR)),
            .CREAT = (flags & O_CREAT) != 0,
            .EXCL = (flags & O_EXCL) != 0,
            .TRUNC = (flags & O_TRUNC) != 0,
            .APPEND = (flags & O_APPEND) != 0,
            .NONBLOCK = (flags & O_NONBLOCK) != 0,
        },
        .wasi => .{
            .read = (flags & O_WRONLY) == 0,
            .write = (flags & O_RDONLY) == 0,
            .CREAT = (flags & O_CREAT) != 0,
            .EXCL = (flags & O_EXCL) != 0,
            .TRUNC = (flags & O_TRUNC) != 0,
            .APPEND = (flags & O_APPEND) != 0,
            .NONBLOCK = (flags & O_NONBLOCK) != 0,
        },
        else => unreachable,
    };
}

const Syscall = if (builtin.os.tag == .macos) enum(i32) {
    exit = 0x2000001,
    read = 0x2000003,
    write = 0x2000004,
    open = 0x2000005,
    close = 0x2000006,
    getppid = 0x2000027,
    creat = 0x2000008,
    brk = 0x20000d6,
} else syscalls.X64;

const Interp = struct {
    const Self = @This();

    memory: std.array_list.AlignedManaged(u8, .of(u32)),
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    pub fn init(
        memory: std.array_list.AlignedManaged(u8, .of(u32)),
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) Self {
        return .{
            .memory = memory,
            .reader = reader,
            .writer = writer,
        };
    }

    pub inline fn next(self: *Self, sp: usize, rsp: usize, ip: usize, target: usize) void {
        _ = target;
        const tgt = @abs(self.readInt(ip));
        const code = @abs(self.readInt(tgt));
        return @call(.always_tail, primitives[code], .{ self, sp, rsp, ip + 4, tgt });
    }

    fn key(self: *Self) !u8 {
        return self.reader.takeByte();
    }

    pub fn word(self: *Self) ![]u8 {
        var ch: u8 = std.ascii.control_code.nul;
        var i: usize = 0;
        var buffer = self.slice(@offsetOf(Header, "buffer"), 0x20);

        while (ch <= ' ') {
            ch = try self.key();
            if (ch == '\\') { // comment ⇒ skip line
                while (ch != '\n') ch = try self.key();
            }
        }
        while (ch > ' ') {
            if (i < F_LENMASK) { // longer names do not fit in the flag byte
                buffer[i] = ch;
                i += 1;
            }
            ch = try self.key();
        }
        return buffer[0..i];
    }

    pub inline fn slice(self: Self, address: usize, len: usize) []u8 {
        // Bounds checking (removing .ptr) breaks HERE @
        return self.memory.items.ptr[address .. address + len];
    }

    pub inline fn writeInt(self: Self, address: usize, val: i32) void {
        mem.writeInt(i32, self.memory.items[address..][0..4], val, native);
    }

    pub inline fn readInt(self: Self, address: usize) i32 {
        return mem.readInt(i32, self.memory.items[address..][0..4], native);
    }

    pub fn find(self: Self, name: []const u8) ?*const Word.Data {
        const mask = @intFromEnum(Flag.HIDDEN) | F_LENMASK;
        const buf = self.memory.items;
        var node: *const Word.Data = @ptrCast(@alignCast(&buf[@abs(self.readInt(@offsetOf(Header, "latest")))]));
        while (node.flag & mask != name.len or !mem.eql(u8, node.name[0..name.len], name)) {
            const link = node.link;
            if (link == .sentinel)
                return null;
            node = @ptrCast(@alignCast(&self.memory.items[@intFromEnum(link)]));
        }
        return node;
    }

    /// `memory` must never be reallocated: `main` hands the stdin and stdout
    /// buffers slices of it, and `slice` hands out unchecked pointers past
    /// `items.len`.  So check against the capacity reserved at startup rather
    /// than growing into a fresh allocation.
    pub inline fn reserve(self: Self, n: usize) void {
        if (self.memory.capacity - self.memory.items.len < n)
            @panic("dictionary is full");
    }

    pub fn append(self: *Self, instr: Address.Data) void {
        self.memory.items.len = @abs(self.readInt(@offsetOf(Header, "here")));
        self.reserve(@sizeOf(Address.Data));
        self.memory.appendSlice(mem.asBytes(&instr)) catch @panic("append cannot appendSlice");
        self.writeInt(@offsetOf(Header, "here"), @intCast(self.memory.items.len));
    }
};

const Header = extern struct {
    stack: [2048]i32,
    return_stack: [2048]u32,
    input_buffer: [2048]u8,
    output_buffer: [2048]u8,
    state: u32,
    here: u32,
    latest: u32,
    s0: u32,
    base: u32,
    cold_start: [1]u32,
    buffer: [32]u8,
};

/// In jonesforth, instructions are simply machine words with context-dependent
/// semantics.  Zig's type system lets us be more explicit.
const Address = enum(u32) {
    sentinel,
    LIT = @offsetOf(Header, "buffer") + 28 + 36 * 0x28, // should be @sizeOf(Word.Data)
    _,

    pub const Data = packed union {
        /// built-in
        code: Word,
        /// LIT, LITSTRING, BRANCH, 0BRANCH, and ' are followed by one argument in the instruction stream
        literal: i32,
        /// written in Forth
        word: Address,
    };
};

const Code = fn (*Interp, usize, usize, usize, usize) callconv(conv) void;

fn wrap(comptime stack: fn ([*]i32) callconv(.@"inline") [*]i32) Code {
    return struct {
        fn code(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
            const s: [*]i32 = @ptrCast(@alignCast(self.memory.items[sp..]));
            const t = stack(s);
            self.next(@intFromPtr(t) - @intFromPtr(self.memory.items.ptr), rsp, ip, target);
        }
    }.code;
}

fn value(comptime literal: i32) Code {
    return struct {
        fn code(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
            self.writeInt(sp - 4, literal);
            self.next(sp - 4, rsp, ip, target);
        }
    }.code;
}

inline fn _drop(sp: [*]i32) [*]i32 {
    return sp + 1;
}

inline fn _swap(sp: [*]i32) [*]i32 {
    const temp = sp[1];
    sp[1] = sp[0];
    sp[0] = temp;
    return sp;
}

inline fn _dup(sp: [*]i32) [*]i32 {
    const s = sp - 1;
    s[0] = sp[0];
    return s;
}

inline fn _over(sp: [*]i32) [*]i32 {
    const s = sp - 1;
    s[0] = sp[1];
    return s;
}

inline fn _rot(sp: [*]i32) [*]i32 {
    const a = sp[0];
    const b = sp[1];
    const c = sp[2];
    sp[2] = b;
    sp[1] = a;
    sp[0] = c;
    return sp;
}

inline fn _nrot(sp: [*]i32) [*]i32 {
    const a = sp[0];
    const b = sp[1];
    const c = sp[2];
    sp[2] = a;
    sp[1] = c;
    sp[0] = b;
    return sp;
}

inline fn _twodrop(sp: [*]i32) [*]i32 {
    return sp + 2;
}

inline fn _twodup(sp: [*]i32) [*]i32 {
    const s = sp - 2;
    s[1] = sp[1];
    s[0] = sp[0];
    return s;
}

inline fn _twoswap(sp: [*]i32) [*]i32 {
    const a = sp[0];
    const b = sp[1];
    const c = sp[2];
    const d = sp[3];
    sp[3] = b;
    sp[2] = a;
    sp[1] = d;
    sp[0] = c;
    return sp;
}

inline fn _qdup(sp: [*]i32) [*]i32 {
    const s = if (sp[0] == 0) sp else sp - 1;
    s[0] = sp[0]; // no-op when TOS is 0
    return s;
}

inline fn _incr(sp: [*]i32) [*]i32 {
    sp[0] += 1;
    return sp;
}

inline fn _decr(sp: [*]i32) [*]i32 {
    sp[0] -= 1;
    return sp;
}

inline fn _incrp(sp: [*]i32) [*]i32 {
    sp[0] += 4;
    return sp;
}

inline fn _decrp(sp: [*]i32) [*]i32 {
    sp[0] -= 4;
    return sp;
}

inline fn _add(sp: [*]i32) [*]i32 {
    sp[1] += sp[0];
    return sp + 1;
}

inline fn _sub(sp: [*]i32) [*]i32 {
    sp[1] -= sp[0];
    return sp + 1;
}

inline fn _mul(sp: [*]i32) [*]i32 {
    sp[1] *= sp[0];
    return sp + 1;
}

inline fn _divmod(sp: [*]i32) [*]i32 {
    const a = sp[1];
    const b = sp[0];
    sp[1] = @rem(a, b);
    sp[0] = @divTrunc(a, b);
    return sp;
}

inline fn _equ(sp: [*]i32) [*]i32 {
    sp[1] = if (sp[1] == sp[0]) -1 else 0;
    return sp + 1;
}

inline fn _nequ(sp: [*]i32) [*]i32 {
    sp[1] = if (sp[1] == sp[0]) 0 else -1;
    return sp + 1;
}

inline fn _lt(sp: [*]i32) [*]i32 {
    sp[1] = if (sp[1] < sp[0]) -1 else 0;
    return sp + 1;
}

inline fn _gt(sp: [*]i32) [*]i32 {
    sp[1] = if (sp[1] > sp[0]) -1 else 0;
    return sp + 1;
}

inline fn _le(sp: [*]i32) [*]i32 {
    sp[1] = if (sp[1] <= sp[0]) -1 else 0;
    return sp + 1;
}

inline fn _ge(sp: [*]i32) [*]i32 {
    sp[1] = if (sp[1] >= sp[0]) -1 else 0;
    return sp + 1;
}

inline fn _zequ(sp: [*]i32) [*]i32 {
    sp[0] = if (sp[0] == 0) -1 else 0;
    return sp;
}

inline fn _znequ(sp: [*]i32) [*]i32 {
    sp[0] = if (sp[0] != 0) -1 else 0;
    return sp;
}

inline fn _zlt(sp: [*]i32) [*]i32 {
    sp[0] = if (sp[0] < 0) -1 else 0;
    return sp;
}

inline fn _zgt(sp: [*]i32) [*]i32 {
    sp[0] = if (sp[0] > 0) -1 else 0;
    return sp;
}

inline fn _zle(sp: [*]i32) [*]i32 {
    sp[0] = if (sp[0] <= 0) -1 else 0;
    return sp;
}

inline fn _zge(sp: [*]i32) [*]i32 {
    sp[0] = if (sp[0] >= 0) -1 else 0;
    return sp;
}

inline fn _and(sp: [*]i32) [*]i32 {
    sp[1] &= sp[0];
    return sp + 1;
}

inline fn _or(sp: [*]i32) [*]i32 {
    sp[1] |= sp[0];
    return sp + 1;
}

inline fn _xor(sp: [*]i32) [*]i32 {
    sp[1] ^= sp[0];
    return sp + 1;
}

inline fn _invert(sp: [*]i32) [*]i32 {
    sp[0] = ~sp[0];
    return sp;
}

fn _exit(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    _ = ip;
    self.next(sp, rsp + 4, @abs(self.readInt(rsp)), target);
}

fn _lit(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(sp - 4, self.readInt(ip));
    self.next(sp - 4, rsp, ip + 4, target);
}

fn _store(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(@abs(self.readInt(sp)), self.readInt(sp + 4));
    self.next(sp + 8, rsp, ip, target);
}

fn _fetch(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(sp, self.readInt(@abs(self.readInt(sp))));
    self.next(sp, rsp, ip, target);
}

fn _addstore(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const p = @abs(self.readInt(sp));
    self.writeInt(p, self.readInt(p) + self.readInt(sp + 4));
    self.next(sp + 8, rsp, ip, target);
}

fn _substore(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const p = @abs(self.readInt(sp));
    self.writeInt(p, self.readInt(p) - self.readInt(sp + 4));
    self.next(sp + 8, rsp, ip, target);
}

fn _storebyte(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const p = @abs(self.readInt(sp));
    const q = @abs(self.readInt(sp + 4));
    self.memory.items.ptr[p] = @truncate(q);
    self.next(sp + 8, rsp, ip, target);
}

fn _fetchbyte(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const p = @abs(self.readInt(sp));
    self.writeInt(sp, self.memory.items[p]);
    self.next(sp, rsp, ip, target);
}

fn _ccopy(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    // ( source dest -- source+1 dest+1 ), per jonesforth.S: dest is on top,
    // source is one cell below; both addresses are left incremented.
    const dest = @abs(self.readInt(sp));
    const source = @abs(self.readInt(sp + 4));

    const memory = self.memory.items.ptr;
    memory[dest] = memory[source];
    self.writeInt(sp, @intCast(dest + 1));
    self.writeInt(sp + 4, @intCast(source + 1));
    self.next(sp, rsp, ip, target);
}

fn _cmove(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    // ( source dest length -- )
    const n = @abs(self.readInt(sp));
    const p = @abs(self.readInt(sp + 4));
    const q = @abs(self.readInt(sp + 8));
    @memcpy(self.slice(p, n), self.slice(q, n));
    self.next(sp + 12, rsp, ip, target);
}

fn _here(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.reserve(@sizeOf(Address));
    self.writeInt(sp - 4, @offsetOf(Header, "here"));
    self.next(sp - 4, rsp, ip, target);
}

fn _argc(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.next(sp, rsp, ip, target);
}

fn docol(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(rsp - 4, @intCast(ip));
    self.next(sp, rsp - 4, target + 4, target);
}

fn _tor(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(rsp - 4, self.readInt(sp));
    self.next(sp + 4, rsp - 4, ip, target);
}

fn _fromr(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(sp - 4, self.readInt(rsp));
    self.next(sp - 4, rsp + 4, ip, target);
}

fn _rspfetch(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(sp - 4, @intCast(rsp));
    self.next(sp - 4, rsp, ip, target);
}

fn _rspstore(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    _ = rsp;
    self.next(sp + 4, @abs(self.readInt(sp)), ip, target);
}

fn _rdrop(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.next(sp, rsp + 4, ip, target);
}

fn _dspfetch(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(sp - 4, @intCast(sp));
    self.next(sp - 4, rsp, ip, target);
}

fn _dspstore(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.next(@abs(self.readInt(sp)), rsp, ip, target);
}

fn _key(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(sp - 4, self.key() catch std.process.exit(0));
    self.next(sp - 4, rsp, ip, target);
}

fn _emit(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const c: u8 = @truncate(@abs(self.readInt(sp)));
    self.writer.print("{c}", .{c}) catch {};
    self.writer.flush() catch {};
    self.next(sp + 4, rsp, ip, target);
}

fn _word(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const word = self.word() catch std.process.exit(0);
    self.writeInt(sp - 4, @offsetOf(Header, "buffer"));
    self.writeInt(sp - 8, @intCast(word.len));
    self.next(sp - 8, rsp, ip, target);
}

fn _number(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    if (fmt.parseInt(i32, self.slice(@abs(self.readInt(sp + 4)), @abs(self.readInt(sp))), @truncate(@abs(self.readInt(@offsetOf(Header, "base")))))) |num| {
        self.writeInt(sp, 0);
        self.writeInt(sp + 4, num);
    } else |_| {}
    self.next(sp, rsp, ip, target);
}

fn _find(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const v = self.find(self.slice(@abs(self.readInt(sp + 4)), @abs(self.readInt(sp))));

    self.writeInt(sp + 4, @intCast(if (v) |ptr| @intFromPtr(ptr) - @intFromPtr(self.memory.items.ptr) else 0));
    self.next(sp + 4, rsp, ip, target);
}

inline fn _tcfa(sp: [*]i32) [*]i32 {
    const w: Address = @enumFromInt(@abs(sp[0]));
    sp[0] = @intCast(codeFieldAddress(w));
    return sp;
}

fn _create(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const name = self.slice(@abs(self.readInt(sp + 4)), @abs(self.readInt(sp)));
    // `Word.Data` is read back through `@alignCast`, and `C,` advances HERE one
    // byte at a time, so a definition that forgets ALIGN would make that UB.
    const here = @abs(self.readInt(@offsetOf(Header, "here")));
    if (here % @alignOf(Word.Data) != 0)
        @panic("_create needs an aligned HERE");
    var word: Word.Data = .{
        .link = @enumFromInt(self.readInt(@offsetOf(Header, "latest"))),
        .flag = @truncate(name.len),
        .name = @splat(0),
        .code = undefined,
    };
    @memcpy(word.name[0..name.len], name);
    self.memory.items.len = here; // C, can leave HERE ahead of items.len
    self.reserve(@sizeOf(Word.Data));
    self.writeInt(@offsetOf(Header, "latest"), @intCast(here));
    self.memory.appendSlice(mem.asBytes(&word)) catch @panic("_create cannot appendSlice");
    self.memory.items.len -= 4; // .code is undefined
    self.writeInt(@offsetOf(Header, "here"), @intCast(self.memory.items.len));
    self.next(sp + 8, rsp, ip, target);
}

fn _comma(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.append(.{ .literal = self.readInt(sp) });
    self.next(sp + 4, rsp, ip, target);
}

fn _lbrac(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(@offsetOf(Header, "state"), 0);
    self.next(sp, rsp, ip, target);
}

fn _rbrac(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(@offsetOf(Header, "state"), 1);
    self.next(sp, rsp, ip, target);
}

fn _immediate(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const w: *Word.Data = @ptrCast(@alignCast(self.slice(@abs(self.readInt(@offsetOf(Header, "latest"))), @sizeOf(Word.Data))));
    w.flag ^= @intFromEnum(Flag.IMMED);
    self.next(sp, rsp, ip, target);
}

fn _hidden(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const w: *Word.Data = @ptrCast(@alignCast(self.slice(@abs(self.readInt(sp)), @sizeOf(Word.Data))));
    w.flag ^= @intFromEnum(Flag.HIDDEN);
    self.next(sp + 4, rsp, ip, target);
}

fn _tick(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.writeInt(sp - 4, self.readInt(ip));
    self.next(sp - 4, rsp, ip + 4, target);
}

fn _branch(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const n = self.readInt(ip);
    const a = @abs(n);
    const p = if (n < 0) ip - a else ip + a;
    self.next(sp, rsp, p, target);
}

fn _zbranch(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    if (self.readInt(sp) == 0)
        return @call(.always_tail, _branch, .{ self, sp + 4, rsp, ip, target });
    self.next(sp + 4, rsp, ip + 4, target);
}

fn _litstring(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const c = self.readInt(ip);
    self.writeInt(sp - 4, @intCast(ip + 4));
    self.writeInt(sp - 8, c);
    self.next(sp - 8, rsp, (ip + @abs(c) + 7) & ~@as(usize, 3), target);
}

fn _tell(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const n = @abs(self.readInt(sp));
    const p = @abs(self.readInt(sp + 4));
    _ = self.writer.write(self.slice(p, n)) catch -1;
    self.writer.flush() catch {};
    self.next(sp + 8, rsp, ip, target);
}

fn _interpret(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const word = self.word() catch return;
    var s = sp;

    if (self.find(word)) |new| {
        const tgt = @intFromPtr(&new.code) - @intFromPtr(self.memory.items.ptr);
        if ((new.flag & @intFromEnum(Flag.IMMED)) != 0 or self.readInt(@offsetOf(Header, "state")) == 0) {
            return @call(.always_tail, primitives[@intFromEnum(new.code)], .{ self, sp, rsp, ip, tgt });
        } else {
            self.append(.{ .word = @enumFromInt(tgt) });
        }
    } else if (fmt.parseInt(i32, word, @intCast(self.readInt(@offsetOf(Header, "base"))))) |a| {
        if (self.readInt(@offsetOf(Header, "state")) == 1) {
            self.append(.{ .word = .LIT });
            self.append(.{ .literal = a });
        } else {
            s -= 4;
            self.writeInt(s, a);
        }
    } else |_| {
        if (word.len == 1 and word[0] == std.ascii.control_code.del)
            return;
        std.debug.print("PARSE ERROR: {s}\n", .{word});
        std.process.exit(0);
    }
    self.next(s, rsp, ip, target);
}

fn _char(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const buf = self.word() catch std.process.exit(0);
    self.writeInt(sp - 4, buf[0]);
    self.next(sp - 4, rsp, ip, target);
}

fn _execute(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    _ = target;
    const target_ = @abs(self.readInt(sp));
    const code = @abs(self.readInt(target_));
    return @call(.always_tail, primitives[code], .{ self, sp + 4, rsp, ip, target_ });
}

inline fn _syscall3(sp: [*]i32) [*]i32 {
    const number_: Syscall = @enumFromInt(sp[0]);

    switch (number_) {
        .open => {
            const p: usize = @abs(sp[1]);
            const file_path: [*:0]u8 = @ptrFromInt(p);
            const mode: std.c.mode_t = @truncate(@abs(sp[3]));
            sp[3] = std.c.openat(std.c.AT.FDCWD, file_path, openFlags(@abs(sp[2])), mode);
        },
        .read => {
            const fd: std.c.fd_t = @intCast(sp[1]);
            const p: usize = @abs(sp[2]);
            const buf: [*]u8 = @ptrFromInt(p);
            const n: usize = @intCast(sp[3]);
            sp[3] = @intCast(std.c.read(fd, buf, n));
        },
        .write => {
            const fd: std.c.fd_t = @intCast(sp[1]);
            const p: usize = @abs(sp[2]);
            const buf: [*]u8 = @ptrFromInt(p);
            const n: usize = @intCast(sp[3]);
            sp[3] = @intCast(std.c.write(fd, buf, n));
        },
        else => {},
    }
    return sp[3..];
}

inline fn _syscall2(sp: [*]i32) [*]i32 {
    const number_: Syscall = @enumFromInt(sp[0]);

    switch (number_) {
        .open => {
            const p: usize = @abs(sp[1]);
            const file_path: [*:0]u8 = @ptrFromInt(p);
            sp[2] = std.c.openat(std.c.AT.FDCWD, file_path, openFlags(@abs(sp[2])));
        },
        else => {},
    }
    return sp[2..];
}

fn _syscall1(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    const number_: Syscall = @enumFromInt(self.readInt(sp));

    switch (number_) {
        .exit => {
            const status: u8 = @truncate(@abs(self.readInt(sp + 4)));
            std.process.exit(status);
        },
        .close => {
            const file: std.c.fd_t = @intCast(self.readInt(sp + 4));
            self.writeInt(sp + 4, std.c.close(file));
        },
        .brk => {
            // brk(0) reports the break; brk(addr) moves it.  Neither can
            // reallocate here, so the break is pinned at the reserved capacity
            // and an out-of-range request fails the way brk(2) does, by
            // returning the unchanged break.
            self.writeInt(sp + 4, @intCast(self.memory.capacity));
        },
        else => {},
    }
    self.next(sp + 4, rsp, ip, target);
}

inline fn _syscall0(sp: [*]i32) [*]i32 {
    const number_: Syscall = @enumFromInt(sp[0]);
    switch (number_) {
        .getppid => {
            sp[0] = if (arch.isWasm())
                @panic("getppid not supported")
            else if (builtin.os.tag == .macos)
                @intCast(std.c.getppid())
            else
                @intCast(os.linux.getppid());
        },
        else => {},
    }
    return sp;
}

test "openFlags translates POSIX O_* bits on the .linux/.macos/.emscripten branch" {
    // This branch covered only .emscripten before; .linux was `unreachable`
    // (a latent bug, since native Linux is the CI test target) and .macos
    // is new. _syscall3's actual open()/read()/write() cases can't be
    // exercised with real pointers here: cells are i32, but a 64-bit host
    // hands out 64-bit heap/stack addresses that don't fit, so this checks
    // the pure flag-translation logic instead.
    if (builtin.os.tag == .wasi) return error.SkipZigTest; // .wasi has a differently-shaped std.c.O

    const AccMode = @TypeOf(@as(std.c.O, undefined).ACCMODE);

    const rdonly = openFlags(O_RDONLY);
    try testing.expectEqual(@as(AccMode, @enumFromInt(O_RDONLY)), rdonly.ACCMODE);
    try testing.expect(!rdonly.CREAT);

    const flags = openFlags(O_WRONLY | O_CREAT | O_TRUNC);
    try testing.expectEqual(@as(AccMode, @enumFromInt(O_WRONLY)), flags.ACCMODE);
    try testing.expect(flags.CREAT);
    try testing.expect(flags.TRUNC);
    try testing.expect(!flags.EXCL);
    try testing.expect(!flags.APPEND);
    try testing.expect(!flags.NONBLOCK);
}

test "_syscall0 getppid matches the host libc/kernel value, including on macOS" {
    // Exercises the portable Syscall enum end-to-end: previously only
    // syscalls.X64 existed, so this path only ever ran on Linux.
    if (arch.isWasm()) return error.SkipZigTest; // .getppid panics under wasm by design

    var stack = [_]i32{@intFromEnum(Syscall.getppid)};
    _ = _syscall0(&stack);
    const expected: i32 = if (builtin.os.tag == .macos) @intCast(std.c.getppid()) else @intCast(os.linux.getppid());
    try testing.expectEqual(expected, stack[0]);
}

test "mode_t truncation does not crash on macOS's 16-bit std.c.mode_t" {
    // Without @truncate this is a compile error on macOS, where mode_t is
    // u16 instead of Linux's u32 (narrower than the i32 cell holding it).
    // 0o644 is a realistic permission value and fits either width unchanged.
    const mode: std.c.mode_t = @truncate(@abs(@as(i32, 0o644)));
    try testing.expectEqual(@as(std.c.mode_t, 0o644), mode);
}

const primitives = [_]*const Code{
    docol,
    wrap(_drop),
    wrap(_swap),
    wrap(_dup),
    wrap(_over),
    wrap(_rot),
    wrap(_nrot),
    wrap(_twodrop),
    wrap(_twodup),
    wrap(_twoswap),
    wrap(_qdup),
    wrap(_incr),
    wrap(_decr),
    wrap(_incrp),
    wrap(_decrp),
    wrap(_add),
    wrap(_sub),
    wrap(_mul),
    wrap(_divmod),
    wrap(_equ),
    wrap(_nequ),
    wrap(_lt),
    wrap(_gt),
    wrap(_le),
    wrap(_ge),
    wrap(_zequ),
    wrap(_znequ),
    wrap(_zlt),
    wrap(_zgt),
    wrap(_zle),
    wrap(_zge),
    wrap(_and),
    wrap(_or),
    wrap(_xor),
    wrap(_invert),
    _exit,
    _lit,
    _store,
    _fetch,
    _addstore,
    _substore,
    _storebyte,
    _fetchbyte,
    _ccopy,
    _cmove,
    value(@offsetOf(Header, "state")),
    value(@offsetOf(Header, "here")),
    value(@offsetOf(Header, "latest")),
    value(@offsetOf(Header, "s0")),
    value(@offsetOf(Header, "base")),
    _argc,
    value(47),
    value(@offsetOf(Header, "input_buffer")),
    value(0),
    value(@intFromEnum(Flag.IMMED)),
    value(@intFromEnum(Flag.HIDDEN)),
    value(F_LENMASK),
    value(@intFromEnum(Syscall.exit)),
    value(@intFromEnum(Syscall.open)),
    value(@intFromEnum(Syscall.close)),
    value(@intFromEnum(Syscall.read)),
    value(@intFromEnum(Syscall.write)),
    value(@intFromEnum(Syscall.creat)),
    value(@intFromEnum(Syscall.brk)),
    value(O_RDONLY),
    value(O_WRONLY),
    value(O_RDWR),
    value(O_CREAT),
    value(O_EXCL),
    value(O_TRUNC),
    value(O_APPEND),
    value(O_NONBLOCK),
    _tor,
    _fromr,
    _rspfetch,
    _rspstore,
    _rdrop,
    _dspfetch,
    _dspstore,
    _key,
    _emit,
    _word,
    _number,
    _find,
    wrap(_tcfa),
    _create,
    _comma,
    _lbrac,
    _rbrac,
    _immediate,
    _hidden,
    _tick,
    _branch,
    _zbranch,
    _litstring,
    _tell,
    _interpret,
    _char,
    _execute,
    wrap(_syscall3),
    wrap(_syscall2),
    _syscall1,
    wrap(_syscall0),
};

const numBytes = @sizeOf(Header) + @sizeOf(Word.Data) * 107 + 30 * @sizeOf(Address.Data);
fn defwords() [numBytes]u8 {
    @setEvalBranchQuota(8_650);
    const names =
        \\DROP SWAP DUP OVER ROT -ROT 2DROP 2DUP 2SWAP ?DUP 1+ 1- 4+ 4- + - * /MOD = <> < > <= >= 0= 0<> 0< 0> 0<= 0>=
        \\AND OR XOR INVERT EXIT LIT ! @ +! -! C! C@ C@C! CMOVE STATE HERE LATEST S0 BASE (ARGC) VERSION R0 DOCOL
        \\F_IMMED F_HIDDEN F_LENMASK SYS_EXIT SYS_OPEN SYS_CLOSE SYS_READ SYS_WRITE SYS_CREAT SYS_BRK
        \\O_RDONLY O_WRONLY O_RDWR O_CREAT O_EXCL O_TRUNC O_APPEND O_NONBLOCK >R R> RSP@ RSP! RDROP DSP@ DSP!
        \\KEY EMIT WORD NUMBER FIND >CFA >DFA CREATE , [ ] IMMEDIATE HIDDEN HIDE : ; ' BRANCH 0BRANCH LITSTRING TELL
        \\INTERPRET QUIT CHAR EXECUTE SYSCALL3 SYSCALL2 SYSCALL1 SYSCALL0
    ;
    const immediate = "[ IMMEDIATE ;";
    const composite: std.StaticStringMap([]const u8) = .initComptime(.{
        .{ ">DFA", ">CFA 4+ EXIT" },
        .{ ":", "WORD CREATE LIT 0 , LATEST @ HIDDEN ] EXIT" },
        .{ ";", "LIT EXIT , LATEST @ HIDDEN [ EXIT" },
        .{ "HIDE", "WORD FIND HIDDEN EXIT" },
        .{ "QUIT", "R0 RSP! INTERPRET BRANCH -8" },
    });
    var latest: u32 = 0;
    var code: u32 = 1;
    var buffer: [numBytes]u8 align(4) = @splat(0);
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.advance(@sizeOf(Header));

    var iter_name = mem.tokenizeAny(u8, names, " \n");
    while (iter_name.next()) |name| {
        const definition = composite.get(name) orelse "";
        var word: Word.Data = .{
            .link = @enumFromInt(latest),
            .flag = @truncate(name.len | if (mem.indexOf(u8, immediate, name)) |_| @intFromEnum(Flag.IMMED) else 0),
            .name = @splat(0),
            .code = @enumFromInt(if (definition.len > 0) 0 else code),
        };
        @memcpy(word.name[0..name.len], name);
        latest = @truncate(writer.end);
        code += if (definition.len > 0) 0 else 1;
        writer.writeStruct(word, native) catch unreachable;

        var it = mem.tokenizeScalar(u8, definition, ' ');
        while (it.next()) |item| {
            if (fmt.parseInt(i32, item, 10)) |num| {
                writer.writeInt(i32, num, native) catch unreachable;
            } else |_| {
                var node = latest;
                while (writer.buffer[node + 4] & F_LENMASK != item.len or !mem.eql(u8, writer.buffer[node + 5 ..][0..item.len], item))
                    node = @bitCast(writer.buffer[node..][0..4].*);
                writer.writeInt(u32, node + @offsetOf(Word.Data, "code"), native) catch unreachable;
            }
        }
    }
    const here = writer.end;

    var quit = latest;
    while (writer.buffer[quit + 4] != 4 or !mem.eql(u8, writer.buffer[quit + 5 ..][0..4], "QUIT"))
        quit = @bitCast(writer.buffer[quit..][0..4].*);

    const header: Header = .{
        .stack = @splat(0),
        .return_stack = @splat(0),
        .input_buffer = @splat(0),
        .output_buffer = @splat(0),
        .state = 0,
        .here = @truncate(here),
        .latest = latest,
        .s0 = @offsetOf(Header, "return_stack"),
        .base = 10,
        .buffer = @splat(0),
        .cold_start = .{quit + @offsetOf(Word.Data, "code")},
    };
    writer.undo(here); // rewind to start
    writer.writeStruct(header, native) catch unreachable;
    return buffer;
}

const initial: [numBytes]u8 align(4) = defwords();

test "defwords" {
    const start = @sizeOf(Header);
    const header: *const Header = @ptrCast(initial[0..start]);
    const words: [*]const Word.Data = @ptrCast(initial[start..]);
    try testing.expectEqual(numBytes, header.here);
    try testing.expectEqual(.sentinel, words[0].link);
    try testing.expectEqualSlices(u8, "DROP", words[0].name[0..words[0].flag]);
    for (words[0..84], 1..) |word, i|
        try testing.expectEqual(i, @intFromEnum(word.code));
    try testing.expectEqual(@as(Address, @enumFromInt(start)), words[1].link);
    try testing.expectEqualSlices(u8, "SWAP", words[1].name[0..words[1].flag]);
    try testing.expectEqualSlices(u8, "R0", words[51].name[0..words[51].flag]);
    try testing.expectEqualSlices(u8, "DOCOL", words[52].name[0..words[52].flag]);
    try testing.expectEqualSlices(u8, ">DFA", words[84].name[0..words[84].flag]);
    try testing.expectEqual(0, @intFromEnum(words[84].code));
    // This is a kludge.  >DFA is composite so its code field is followed by 3 data field.
    // >DFA's first data field occupies words[85].link
    try testing.expectEqual(@as(Address, @enumFromInt(codeFieldAddress(words[84].link))), words[85].link);

    var node: u32 = @offsetOf(Header, "cold_start"); // points to CFA of "QUIT"
    node = mem.readInt(u32, initial[node..][0..4], native);
    try testing.expectEqual(0, mem.readInt(u32, initial[node..][0..4], native)); // CFA of "QUIT" is DOCOL ✓
    node = mem.readInt(u32, initial[node + 4 ..][0..4], native); // follow link to CFA of "R0"
    try testing.expectEqual(52, mem.readInt(u32, initial[node..][0..4], native)); // CFA of "R0" is R0 ✓
}

fn cold_start(self: *Interp, sp: usize, rsp: usize, ip: usize, target: usize) callconv(conv) void {
    self.next(sp, rsp, ip, target);
}

fn run(memory: std.array_list.AlignedManaged(u8, .@"4"), reader: *std.Io.Reader, writer: *std.Io.Writer) void {
    var env: Interp = .init(memory, reader, writer);

    cold_start(
        &env,
        @offsetOf(Header, "return_stack"),
        @offsetOf(Header, "input_buffer"),
        @offsetOf(Header, "cold_start"),
        0,
    );
}

pub fn main(init: std.process.Init) !void {
    var memory: std.array_list.AlignedManaged(u8, .@"4") = try .initCapacity(init.gpa, 0x20_000);
    defer memory.deinit();
    try memory.appendSlice(initial[0..]);
    var header: *Header = @ptrCast(memory.items.ptr);
    var stdin_reader = std.Io.File.stdin().reader(init.io, header.input_buffer[0..]);
    var stdout_writer = std.Io.File.stdout().writer(init.io, header.output_buffer[0..]);

    run(memory, &stdin_reader.interface, &stdout_writer.interface);
}

fn forth(input: []const u8, expected: [:0]const u8) !void {
    var memory: std.array_list.AlignedManaged(u8, .@"4") = try .initCapacity(testing.allocator, 0x10_000);
    defer memory.deinit();
    try memory.appendSlice(initial[0..]);

    var reader: std.Io.Reader = .fixed(input);

    var actual = mem.zeroes([2048]u8);
    var writer: std.Io.Writer = .fixed(&actual);
    run(memory, &reader, &writer);
    try testing.expectEqualSlices(u8, expected, mem.sliceTo(actual[0..], 0));
}

test forth {
    // This is a stripped version of https://github.com/nornagon/jonesforth/blob/master/jonesforth.S
    // to bootstrap just enough "high-level" Forth so this test achieves reasonable coverage.
    const preamble =
        \\: / /MOD SWAP DROP ;
        \\: '\n' 10 ;
        \\: BL 32 ;
        \\: CR '\n' EMIT ;
        \\: SPACE BL EMIT ;
        \\: NEGATE 0 SWAP - ;
        \\: TRUE 1 ;
        \\: FALSE 0 ;
        \\: LITERAL IMMEDIATE ' LIT , , ;
        \\: ':' [ CHAR : ] LITERAL ;
        \\: ';' [ CHAR ; ] LITERAL ;
        \\: '"' [ CHAR " ] LITERAL ;
        \\: 'A' [ CHAR A ] LITERAL ;
        \\: '0' [ CHAR 0 ] LITERAL ;
        \\: '-' [ CHAR - ] LITERAL ;
        \\: [COMPILE] IMMEDIATE WORD FIND >CFA , ;
        \\: RECURSE   IMMEDIATE LATEST @ >CFA , ;
        \\: IF        IMMEDIATE ' 0BRANCH , HERE @ 0 , ;
        \\: THEN      IMMEDIATE DUP HERE @ SWAP - SWAP ! ;
        \\: ELSE      IMMEDIATE ' BRANCH , HERE @ 0 , SWAP DUP HERE @ SWAP - SWAP ! ;
        \\: BEGIN     IMMEDIATE HERE @ ;
        \\: AGAIN     IMMEDIATE ' BRANCH , HERE @ - , ;
        \\: WHILE     IMMEDIATE ' 0BRANCH , HERE @ 0 , ;
        \\: REPEAT    IMMEDIATE ' BRANCH , SWAP HERE @ - , DUP HERE @ SWAP - SWAP ! ;
        \\: NIP SWAP DROP ;
        \\: PICK 1+ 4 * DSP@ + @ ;
        \\: SPACES BEGIN DUP 0> WHILE SPACE 1- REPEAT DROP ;
        \\: U. BASE @ /MOD ?DUP IF RECURSE THEN DUP 10 < IF '0' ELSE 10 - 'A' THEN + EMIT ;
        \\: .S DSP@ BEGIN DUP S0 @ < WHILE DUP @ U. 4+ SPACE REPEAT DROP ;
        \\: UWIDTH BASE @ / ?DUP IF RECURSE 1+ ELSE 1 THEN ;
        \\: U.R SWAP DUP UWIDTH ROT SWAP - SPACES U. ;
        \\: .R SWAP DUP 0< IF NEGATE 1 SWAP ROT 1- ELSE 0 SWAP ROT THEN SWAP DUP UWIDTH ROT SWAP - SPACES SWAP IF '-' EMIT THEN U. ;
        \\: . 0 .R SPACE ;
        \\: U. U. SPACE ;
        \\: WITHIN -ROT OVER <= IF > IF TRUE ELSE FALSE THEN ELSE 2DROP FALSE THEN ;
        \\: ALIGNED 3 + -4 AND ;
        \\: ALIGN HERE @ ALIGNED HERE ! ;
        \\: C, HERE @ C! 1 HERE +! ;
        \\: S" IMMEDIATE STATE @ IF
        \\  ' LITSTRING , HERE @ 0 , BEGIN KEY DUP '"' <> WHILE C, REPEAT DROP DUP HERE @ SWAP - 4- SWAP ! ALIGN ELSE
        \\  HERE @ BEGIN KEY DUP '"' <> WHILE OVER C! 1+ REPEAT DROP HERE @ - HERE @ SWAP THEN ;
        \\: ." IMMEDIATE STATE @ IF [COMPILE] S" ' TELL , ELSE BEGIN KEY DUP '"' = IF DROP EXIT THEN EMIT AGAIN THEN ;
        \\: CELLS 4 * ;
        \\: ID. 4+ DUP C@ F_LENMASK AND BEGIN DUP 0> WHILE SWAP 1+ DUP C@ EMIT SWAP 1- REPEAT 2DROP ;
        \\: ?IMMEDIATE 4+ C@ F_IMMED AND ;
        \\: CASE    IMMEDIATE 0 ;
        \\: OF      IMMEDIATE ' OVER , ' = , [COMPILE] IF ' DROP , ;
        \\: ENDOF   IMMEDIATE [COMPILE] ELSE ;
        \\: ENDCASE IMMEDIATE ' DROP , BEGIN ?DUP WHILE [COMPILE] THEN REPEAT ;
        \\: CFA> LATEST @ BEGIN ?DUP WHILE 2DUP SWAP < IF NIP EXIT THEN @ REPEAT DROP 0 ;
        \\: SEE WORD FIND HERE @ LATEST @ BEGIN 2 PICK OVER <> WHILE NIP DUP @ REPEAT DROP SWAP
        \\  ':' EMIT SPACE DUP ID. SPACE DUP ?IMMEDIATE IF ." IMMEDIATE " THEN >DFA
        \\  BEGIN 2DUP > WHILE DUP @
        \\      CASE
        \\          ' LIT OF 4+ DUP @ . ENDOF
        \\          ' LITSTRING OF [ CHAR S ] LITERAL EMIT '"' EMIT SPACE 4+ DUP @ SWAP 4+ SWAP 2DUP TELL '"' EMIT SPACE + ALIGNED 4- ENDOF
        \\          ' 0BRANCH OF ." 0BRANCH ( " 4+ DUP @ . ." ) " ENDOF
        \\          '  BRANCH OF  ." BRANCH ( " 4+ DUP @ . ." ) " ENDOF
        \\          ' ' OF [ CHAR ' ] LITERAL EMIT SPACE 4+ DUP CFA> ID. SPACE ENDOF
        \\          ' EXIT OF 2DUP 4+ <> IF ." EXIT " THEN ENDOF
        \\          DUP CFA> ID. SPACE
        \\      ENDCASE
        \\      4+
        \\  REPEAT
        \\ ';' EMIT CR 2DROP ;
        \\: ['] IMMEDIATE ' LIT , ;
        \\: EXCEPTION-MARKER RDROP 0 ;
        \\: CATCH DSP@ 4+ >R ' EXCEPTION-MARKER 4+ >R EXECUTE ;
        \\: THROW ?DUP IF RSP@ BEGIN DUP R0 4- < WHILE DUP @ ' EXCEPTION-MARKER 4+ = IF 4+ RSP! DUP DUP DUP R> 4- SWAP OVER ! DSP! EXIT THEN 4+ REPEAT
        \\  DROP CASE 0 1- OF ." ABORTED" CR ENDOF ." UNCAUGHT THROW " DUP . CR ENDCASE QUIT THEN ;
        \\: STRLEN DUP BEGIN DUP C@ 0<> WHILE 1+ REPEAT SWAP - ;
        \\
    ;
    const tests = .{
        .{ "65 EMIT ", "A" },
        .{ "777 65 EMIT ", "A" },
        .{ "32 DUP + 1+ EMIT ", "A" },
        .{ "16 DUP 2DUP + + + 1+ EMIT ", "A" },
        .{ "8 DUP * 1+ EMIT ", "A" },
        .{ "CHAR A EMIT ", "A" },
        .{ ": SLOW WORD FIND >CFA EXECUTE ; 65 SLOW EMIT ", "A" },
        .{ "1179010630 DSP@ 4 TELL ", "FFFF" },
        .{ "1179010630 DSP@ HERE @ 4 CMOVE HERE @ 4 TELL ", "FFFF" },
        // CMOVE consumes all three arguments, so only the literal is left
        .{ preamble ++ "1179010630 DSP@ HERE @ 4 CMOVE .S ", "1179010630 " },
        .{ "13622 DSP@ 2 NUMBER DROP EMIT ", "A" },
        .{ "64 >R RSP@ 1 TELL RDROP ", "@" },
        .{ "64 DSP@ RSP@ C@C! RSP@ 1 TELL ", "@" },
        .{ "64 >R 1 RSP@ +! RSP@ 1 TELL ", "A" },
        .{ preamble ++ "VERSION . ", "47 " },
        .{ preamble ++ "CR ", "\n" },
        .{ preamble ++ "0 1 > . 1 0 > . ", "0 -1 " },
        .{ preamble ++ "0 1 >= . 0 0 >= . ", "0 -1 " },
        .{ preamble ++ "0 0<> . 1 0<> . ", "0 -1 " },
        .{ preamble ++ "1 0<= . 0 0<= . ", "0 -1 " },
        .{ preamble ++ "-1 0>= . 0 0>= . ", "0 -1 " },
        .{ preamble ++ "0 0 OR . 0 -1 OR . ", "0 -1 " },
        .{ preamble ++ "-1 -1 XOR . 0 -1 XOR . ", "0 -1 " },
        .{ preamble ++ "-1 INVERT . 0 INVERT . ", "0 -1 " },
        .{ preamble ++ "3 4 5 .S ", "5 4 3 " },
        .{ preamble ++ "1 2 3 4 2SWAP .S ", "2 1 4 3 " },
        .{ preamble ++ "F_IMMED F_HIDDEN .S ", "32 128 " },
        .{ preamble ++ ": CFA@ WORD FIND >CFA @ ; CFA@ >DFA DOCOL = . ", "-1 " },
        .{ preamble ++ "3 4 5 WITHIN . ", "0 " },
        .{ preamble ++ "SEE >DFA ", ": >DFA >CFA 4+ ;\n" },
        .{ preamble ++ "SEE HIDE ", ": HIDE WORD FIND HIDDEN ;\n" },
        .{ preamble ++ "SEE QUIT ", ": QUIT R0 RSP! INTERPRET BRANCH ( -8 ) ;\n" },
        .{ preamble ++ "SEE / ", ": / /MOD SWAP DROP ;\n" },
        // a 4-byte LITSTRING pins the padding arithmetic
        .{ preamble ++ ": PAD4 .\" ABCD\" ; PAD4 ", "ABCD" },
        // built-in headers really are writable
        .{ preamble ++ "HIDE (ARGC) WORD (ARGC) FIND 0= . ", "-1 " },
        .{
            preamble ++
                \\: FOO THROW ;
                \\: TEST-EXCEPTIONS 25 ['] FOO CATCH ?DUP IF ." FOO threw exception: " . CR DROP THEN ;
                \\TEST-EXCEPTIONS 
            ,
            "FOO threw exception: 25 \n",
        },
    };

    inline for (tests) |t|
        try forth(t.@"0", t.@"1");

    if (!arch.isWasm()) {
        const ppid = if (builtin.os.tag == .macos) std.c.getppid() else os.linux.getppid();
        const p = try fmt.allocPrintSentinel(testing.allocator, "{d} ", .{ppid}, 0);
        defer testing.allocator.free(p);

        try forth(preamble ++ fmt.comptimePrint(": GETPPID {d} SYSCALL0 ; GETPPID . ", .{@intFromEnum(Syscall.getppid)}), p);
    }
}
