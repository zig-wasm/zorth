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
const native_endian = arch.endian();

const conv: std.builtin.CallingConvention = switch (arch) {
    .x86_64 => .winapi,
    else => .auto,
};

const O_RDONLY = 0o0;
const O_WRONLY = 0o1;
const O_RDWR = 0o2;
const O_CREAT = 0o100;
const O_EXCL = 0o200;
const O_TRUNC = 0o1000;
const O_APPEND = 0o2000;
const O_NONBLOCK = 0o4000;
const F_LENMASK = std.ascii.control_code.us;
const Flag = enum(u8) { IMMED = 0x80, HIDDEN = ' ', ZERO = 0x0 };

/// The layout of this `struct` is very important for introspection to work.
/// Ideally, we would use [flexible array members](https://en.wikipedia.org/wiki/Flexible_array_member)
/// but I'm not sure how they work in Zig.  So I lie a little and `Word` only
/// represents metadata.  "Real" words are arrays of `Instr` whose first
/// `offset` elements are disgustingly `@ptrCast`ed to a `Word` when
/// necessary.  Ugh.
const Word = extern struct {
    link: ?*const Word,
    flag: u8,
    name: [F_LENMASK]u8 align(1),
    code: usize,
};

const offset = @divExact(@sizeOf(Word), @sizeOf(Instr));

inline fn codeFieldAddress(w: [*]const Instr) usize {
    return @intFromPtr(w + offset);
}

inline fn openFlags(flags: usize) std.c.O {
    return switch (builtin.os.tag) {
        .emscripten => .{
            .ACCMODE = @enumFromInt(flags & O_RDWR),
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

const Interp = struct {
    const Self = @This();

    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    state: isize,
    latest: *Word,
    argv: []const [*:0]const u8,
    s0: [*]const isize,
    base: isize,
    r0: [*]const [*]const Instr,
    buffer: [32]u8,
    memory: *std.array_list.AlignedManaged(u8, .of(usize)),
    here: [*]u8,

    pub fn init(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        argv: []const [*:0]const u8,
        sp: []const isize,
        rsp: []const [*]const Instr,
        m: *std.array_list.AlignedManaged(u8, .of(usize)),
        latest: usize,
    ) Self {
        m.ensureUnusedCapacity(@sizeOf(Instr)) catch @panic("init cannot ensureUnusedCapacity");
        return .{
            .reader = reader,
            .writer = writer,
            .state = 0,
            .latest = @ptrCast(@alignCast(m.items.ptr + latest)),
            .argv = argv,
            .s0 = sp.ptr,
            .base = 10,
            .r0 = rsp.ptr,
            .buffer = undefined,
            .memory = m,
            .here = m.items.ptr + m.items.len,
        };
    }

    pub inline fn targetPtr(self: *Self, index: usize) [*]const Instr {
        const ptr: [*]const Instr = @ptrCast(self.memory.items.ptr);
        return ptr + index;
    }

    pub inline fn next(self: *Self, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) void {
        _ = target;
        const tgt = self.targetPtr(ip[0].word);
        return @call(.always_tail, primitive(tgt), .{ self, sp, rsp, ip[1..], tgt });
    }

    fn key(self: *Self) !u8 {
        return self.reader.takeByte();
    }

    pub fn word(self: *Self) !usize {
        var ch: u8 = std.ascii.control_code.nul;
        var i: usize = 0;

        while (ch <= ' ') {
            ch = try self.key();
            if (ch == '\\') { // comment ⇒ skip line
                while (ch != '\n') ch = try self.key();
            }
        }
        while (ch > ' ') {
            self.buffer[i] = ch;
            i += 1;
            ch = try self.key();
        }
        return i;
    }

    pub fn find(self: Self, name: []const u8) ?*const Word {
        const mask = @intFromEnum(Flag.HIDDEN) | F_LENMASK;
        var node: *const Word = self.latest;
        while (node.flag & mask != name.len or !mem.eql(u8, node.name[0..name.len], name))
            node = node.link orelse return null;

        return node;
    }

    pub fn append(self: *Self, instr: Instr) void {
        self.memory.items.len = @intFromPtr(self.here) - @intFromPtr(self.memory.items.ptr);
        self.memory.appendSlice(mem.asBytes(&instr)) catch @panic("append cannot appendSlice");
        self.here = self.memory.items.ptr + self.memory.items.len;
    }
};

/// In jonesforth, instructions are simply machine words with context-dependent
/// semantics.  Zig's type system lets us be more explicit.
const Instr = packed union(usize) {
    /// built-in
    code: usize,
    /// LIT, LITSTRING, BRANCH, 0BRANCH, and ' are followed by one argument in the instruction stream
    literal: isize,
    /// written in Forth
    word: usize,
};

const Code = fn (*Interp, [*]isize, [*][*]const Instr, [*]const Instr, [*]const Instr) callconv(conv) void;

pub fn primitive(target: [*]const Instr) *const Code {
    return primitives[target[0].code];
}

fn wrap(comptime stack: fn ([*]isize) callconv(.@"inline") [*]isize) Code {
    return struct {
        fn code(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
            self.next(stack(sp), rsp, ip, target);
        }
    }.code;
}

fn attr(comptime name: []const u8) Code {
    return struct {
        fn code(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
            const s = sp - 1;
            s[0] = @intCast(@intFromPtr(&@field(self, name)));
            self.next(s, rsp, ip, target);
        }
    }.code;
}

fn value(comptime literal: isize) Code {
    return struct {
        fn code(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
            const s = sp - 1;
            s[0] = literal;
            self.next(s, rsp, ip, target);
        }
    }.code;
}

inline fn _drop(sp: [*]isize) [*]isize {
    return sp[1..];
}

inline fn _swap(sp: [*]isize) [*]isize {
    const temp = sp[1];
    sp[1] = sp[0];
    sp[0] = temp;
    return sp;
}

inline fn _dup(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = sp[0];
    return s;
}

inline fn _over(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = sp[1];
    return s;
}

inline fn _rot(sp: [*]isize) [*]isize {
    const a = sp[0];
    const b = sp[1];
    const c = sp[2];
    sp[2] = b;
    sp[1] = a;
    sp[0] = c;
    return sp;
}

inline fn _nrot(sp: [*]isize) [*]isize {
    const a = sp[0];
    const b = sp[1];
    const c = sp[2];
    sp[2] = a;
    sp[1] = c;
    sp[0] = b;
    return sp;
}

inline fn _twodrop(sp: [*]isize) [*]isize {
    return sp[2..];
}

inline fn _twodup(sp: [*]isize) [*]isize {
    const s = sp - 2;
    s[1] = sp[1];
    s[0] = sp[0];
    return s;
}

inline fn _twoswap(sp: [*]isize) [*]isize {
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

inline fn _qdup(sp: [*]isize) [*]isize {
    if (sp[0] != 0) {
        const s = sp - 1;
        s[0] = sp[0];
        return s;
    }
    return sp;
}

inline fn _incr(sp: [*]isize) [*]isize {
    sp[0] += 1;
    return sp;
}

inline fn _decr(sp: [*]isize) [*]isize {
    sp[0] -= 1;
    return sp;
}

inline fn _incrp(sp: [*]isize) [*]isize {
    sp[0] += @sizeOf(usize);
    return sp;
}

inline fn _decrp(sp: [*]isize) [*]isize {
    sp[0] -= @sizeOf(usize);
    return sp;
}

inline fn _add(sp: [*]isize) [*]isize {
    sp[1] += sp[0];
    return sp[1..];
}

inline fn _sub(sp: [*]isize) [*]isize {
    sp[1] -= sp[0];
    return sp[1..];
}

inline fn _mul(sp: [*]isize) [*]isize {
    sp[1] *= sp[0];
    return sp[1..];
}

inline fn _divmod(sp: [*]isize) [*]isize {
    const a = sp[1];
    const b = sp[0];
    sp[1] = @rem(a, b);
    sp[0] = @divTrunc(a, b);
    return sp;
}

inline fn _equ(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] == sp[0]) -1 else 0;
    return sp[1..];
}

inline fn _nequ(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] == sp[0]) 0 else -1;
    return sp[1..];
}

inline fn _lt(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] < sp[0]) -1 else 0;
    return sp[1..];
}

inline fn _gt(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] > sp[0]) -1 else 0;
    return sp[1..];
}

inline fn _le(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] <= sp[0]) -1 else 0;
    return sp[1..];
}

inline fn _ge(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] >= sp[0]) -1 else 0;
    return sp[1..];
}

inline fn _zequ(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] == 0) -1 else 0;
    return sp;
}

inline fn _znequ(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] != 0) -1 else 0;
    return sp;
}

inline fn _zlt(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] < 0) -1 else 0;
    return sp;
}

inline fn _zgt(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] > 0) -1 else 0;
    return sp;
}

inline fn _zle(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] <= 0) -1 else 0;
    return sp;
}

inline fn _zge(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] >= 0) -1 else 0;
    return sp;
}

inline fn _and(sp: [*]isize) [*]isize {
    sp[1] &= sp[0];
    return sp[1..];
}

inline fn _or(sp: [*]isize) [*]isize {
    sp[1] |= sp[0];
    return sp[1..];
}

inline fn _xor(sp: [*]isize) [*]isize {
    sp[1] ^= sp[0];
    return sp[1..];
}

inline fn _invert(sp: [*]isize) [*]isize {
    sp[0] = ~sp[0];
    return sp;
}

fn _exit(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    _ = ip;
    self.next(sp, rsp[1..], rsp[0], target);
}

fn _lit(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    s[0] = ip[0].literal;
    self.next(s, rsp, ip[1..], target);
}

inline fn _store(sp: [*]isize) [*]isize {
    const p: *isize = @ptrFromInt(@abs(sp[0]));
    p.* = sp[1];
    return sp[2..];
}

inline fn _fetch(sp: [*]isize) [*]isize {
    const p: *isize = @ptrFromInt(@abs(sp[0]));
    sp[0] = p.*;
    return sp;
}

inline fn _addstore(sp: [*]isize) [*]isize {
    const p: *[*]u8 = @ptrFromInt(@abs(sp[0]));
    p.* += @abs(sp[1]);
    return sp[2..];
}

inline fn _substore(sp: [*]isize) [*]isize {
    const p: *[*]u8 = @ptrFromInt(@abs(sp[0]));
    p.* -= @abs(sp[1]);
    return sp[2..];
}

inline fn _storebyte(sp: [*]isize) [*]isize {
    const p: [*]u8 = @ptrFromInt(@abs(sp[0]));
    const v: u8 = @truncate(@abs(sp[1]));
    p[0] = v;
    return sp[2..];
}

inline fn _fetchbyte(sp: [*]isize) [*]isize {
    const p: [*]u8 = @ptrFromInt(@abs(sp[0]));
    sp[0] = p[0];
    return sp;
}

inline fn _ccopy(sp: [*]isize) [*]isize {
    const p: [*]u8 = @ptrFromInt(@abs(sp[0]));
    const q: [*]u8 = @ptrFromInt(@abs(sp[1]));
    q[0] = p[0];
    return sp[2..];
}

inline fn _cmove(sp: [*]isize) [*]isize {
    const n = @abs(sp[0]);
    @memcpy(dest: {
        const p: [*]u8 = @ptrFromInt(@abs(sp[1]));
        break :dest p[0..n];
    }, source: {
        const q: [*]u8 = @ptrFromInt(@abs(sp[2]));
        break :source q[0..n];
    });
    sp[2] = sp[1];
    return sp[2..];
}

fn _here(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    self.memory.ensureUnusedCapacity(@sizeOf(Instr)) catch @panic("_here cannot ensureUnusedCapacity");
    s[0] = @intCast(@intFromPtr(&self.here));
    self.next(s, rsp, ip, target);
}

fn _argc(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    const u = @intFromPtr(self.argv.ptr - 1);
    s[0] = @intCast(u);
    self.next(s, rsp, ip, target);
}

fn _rz(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    const u = @intFromPtr(self.r0);
    s[0] = @intCast(u);
    self.next(s, rsp, ip, target);
}

fn docol_(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const r = rsp - 1;
    r[0] = ip;
    self.next(sp, r, target[1..], target);
}

fn dodoes_(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const r = rsp - 1;
    const s = sp - 1;
    r[0] = ip;
    s[0] = @intCast(@intFromPtr(&target[2]));
    self.next(s, r, self.targetPtr(target[1].word), target);
}

inline fn _dodoes(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(&dodoes_));
    return s;
}

fn _tor(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const r = rsp - 1;
    const t: [*]Instr = @ptrFromInt(@abs(sp[0]));
    r[0] = t;
    self.next(sp[1..], r, ip, target);
}

fn _fromr(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(rsp[0]));
    self.next(s, rsp[1..], ip, target);
}

fn _rspfetch(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(rsp));
    self.next(s, rsp, ip, target);
}

fn _rspstore(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    _ = rsp;
    const s = @abs(sp[0]);
    const t: [*][*]const Instr = @ptrFromInt(s);
    self.next(sp[1..], t, ip, target);
}

fn _rdrop(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    self.next(sp, rsp[1..], ip, target);
}

inline fn _dspfetch(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(sp));
    return s;
}

inline fn _dspstore(sp: [*]isize) [*]isize {
    const u = @abs(sp[0]);
    const p: [*]isize = @ptrFromInt(u);
    return p;
}

fn _key(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    s[0] = @intCast(self.key() catch std.process.exit(0));
    self.next(s, rsp, ip, target);
}

fn _emit(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const c: u8 = @truncate(@abs(sp[0]));
    self.writer.print("{c}", .{c}) catch {};
    self.writer.flush() catch {};
    self.next(sp[1..], rsp, ip, target);
}

fn _word(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 2;
    const u = @intFromPtr(&self.buffer);
    s[1] = @intCast(u);
    s[0] = @intCast(self.word() catch std.process.exit(0));
    self.next(s, rsp, ip, target);
}

fn _number(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    if (fmt.parseInt(isize, buf: {
        const s: [*]u8 = @ptrFromInt(@abs(sp[1]));
        break :buf s[0..@abs(sp[0])];
    }, @truncate(@abs(self.base)))) |num| {
        sp[1] = num;
        sp[0] = 0;
    } else |_| {}
    self.next(sp, rsp, ip, target);
}

fn _find(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s: [*]u8 = @ptrFromInt(@abs(sp[1]));
    const v = self.find(s[0..@abs(sp[0])]);

    sp[1] = @intCast(@intFromPtr(v));
    self.next(sp[1..], rsp, ip, target);
}

inline fn _tcfa(sp: [*]isize) [*]isize {
    const w: [*]const Instr = @ptrFromInt(@abs(sp[0]));
    sp[0] = @intCast(codeFieldAddress(w));
    return sp;
}

fn _create(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const c = @abs(sp[0]);
    const s: [*]u8 = @ptrFromInt(@abs(sp[1]));
    const code = self.memory.addManyAsSlice(@sizeOf(Word)) catch @panic("_create cannot addManyAsSlice");
    var new: *Word = @ptrCast(@alignCast(code.ptr));
    new.link = self.latest;
    new.flag = @truncate(c);
    @memcpy(new.name[0..c], s[0..c]);
    @memset(new.name[c..F_LENMASK], 0);
    self.latest = new;
    self.here = self.memory.items.ptr + self.memory.items.len;
    self.next(sp[2..], rsp, ip, target);
}

fn _comma(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s: isize = sp[0];
    const instr: Instr = if (s == 0)
        .{ .code = 0 } // docol_
    else if (s < 0x1000)
        .{ .literal = s }
    else
        .{ .word = @abs(s) };
    self.append(instr);
    self.next(sp[1..], rsp, ip, target);
}

fn _lbrac(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    self.state = 0;
    self.next(sp, rsp, ip, target);
}

fn _rbrac(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    self.state = 1;
    self.next(sp, rsp, ip, target);
}

fn _immediate(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    self.latest.flag ^= @intFromEnum(Flag.IMMED);
    self.next(sp, rsp, ip, target);
}

inline fn _hidden(sp: [*]isize) [*]isize {
    const w: *Word = @ptrFromInt(@abs(sp[0]));
    w.flag ^= @intFromEnum(Flag.HIDDEN);
    return sp[1..];
}

fn _tick(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    s[0] = @intCast(ip[0].word);
    self.next(s, rsp, ip[1..], target);
}

fn _branch(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const n = @divTrunc(ip[0].literal, @sizeOf(Instr));
    const a = @abs(n);
    const p = if (n < 0) ip - a else ip + a;
    self.next(sp, rsp, p, target);
}

fn _zbranch(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    if (sp[0] == 0)
        return @call(.always_tail, _branch, .{ self, sp[1..], rsp, ip, target });
    self.next(sp[1..], rsp, ip[1..], target);
}

fn _litstring(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const c = @abs(ip[0].literal);
    const s = sp - 2;
    s[1] = @intCast(@intFromPtr(&ip[1]));
    s[0] = @intCast(c);
    const n = @abs(1 + @divTrunc(c + @sizeOf(Instr), @sizeOf(Instr)));
    self.next(s, rsp, ip[n..], target);
}

fn _tell(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const p: [*]u8 = @ptrFromInt(@abs(sp[1]));
    _ = self.writer.write(p[0..@abs(sp[0])]) catch -1;
    self.writer.flush() catch {};
    self.next(sp[2..], rsp, ip, target);
}

fn _interpret(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const c = self.word() catch return;
    var s = sp;

    if (self.find(self.buffer[0..c])) |new| {
        const tgt = codeFieldAddress(@ptrCast(new));
        const instrs = self.targetPtr(tgt);
        if ((new.flag & @intFromEnum(Flag.IMMED)) != 0 or self.state == 0) {
            return @call(.always_tail, primitive(instrs), .{ self, sp, rsp, ip, instrs });
        } else {
            self.append(.{ .word = tgt });
        }
    } else if (fmt.parseInt(isize, self.buffer[0..c], @truncate(@abs(self.base)))) |a| {
        if (self.state == 1) {
            self.append(.{ .word = @intFromPtr(&.{.{ .code = 36 }}) });
            self.append(.{ .literal = a });
        } else {
            s = sp - 1;
            s[0] = a;
        }
    } else |_| {
        if (c == 1 and self.buffer[0] == std.ascii.control_code.del)
            return;
        std.debug.print("PARSE ERROR: {s}\n", .{self.buffer[0..c]});
        std.process.exit(0);
    }
    self.next(s, rsp, ip, target);
}

fn _char(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    _ = self.word() catch std.process.exit(0);
    s[0] = self.buffer[0];
    self.next(s, rsp, ip, target);
}

fn _execute(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    _ = target;
    const target_ = self.targetPtr(@abs(sp[0]));
    return @call(.always_tail, primitive(target_), .{ self, sp[1..], rsp, ip, target_ });
}

inline fn _syscall3(sp: [*]isize) [*]isize {
    const number_: syscalls.X64 = @enumFromInt(sp[0]);

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
            sp[3] = std.c.read(fd, buf, n);
        },
        .write => {
            const fd: std.c.fd_t = @intCast(sp[1]);
            const p: usize = @abs(sp[2]);
            const buf: [*]u8 = @ptrFromInt(p);
            const n: usize = @intCast(sp[3]);
            sp[3] = std.c.write(fd, buf, n);
        },
        else => {},
    }
    return sp[3..];
}

inline fn _syscall2(sp: [*]isize) [*]isize {
    const number_: syscalls.X64 = @enumFromInt(sp[0]);

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

fn _syscall1(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const number_: syscalls.X64 = @enumFromInt(sp[0]);

    switch (number_) {
        .exit => {
            const status: u8 = @truncate(@abs(sp[1]));
            std.process.exit(status);
        },
        .close => {
            const file: std.c.fd_t = @intCast(sp[1]);
            sp[1] = std.c.close(file);
        },
        .brk => {
            const m = @abs(sp[1]);
            const p: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(self.memory.allocator.ptr));
            if (m > 0) {
                const n = if (arch.isWasm())
                    @wasmMemoryGrow(0, @divTrunc(m, 0x10000))
                else
                    os.linux.syscall1(.brk, m);
                if (n < m)
                    @panic("brk syscall failed");
                p.buffer.len = m - @intFromPtr(p.buffer.ptr);
            }
            sp[1] = @intCast(@intFromPtr(p.buffer.ptr + p.buffer.len));
        },
        else => {},
    }
    self.next(sp[1..], rsp, ip, target);
}

inline fn _syscall0(sp: [*]isize) [*]isize {
    const number_: syscalls.X64 = @enumFromInt(sp[0]);
    switch (number_) {
        .getppid => {
            sp[0] = if (arch.isWasm())
                @panic("getppid not supported")
            else
                @intCast(os.linux.getppid());
        },
        else => {},
    }
    return sp;
}

const primitives: [104]*const Code = .{
    docol_,
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
    wrap(_store),
    wrap(_fetch),
    wrap(_addstore),
    wrap(_substore),
    wrap(_storebyte),
    wrap(_fetchbyte),
    wrap(_ccopy),
    wrap(_cmove),
    attr("state"),
    attr("here"),
    attr("latest"),
    attr("s0"),
    attr("base"),
    _argc,
    value(47),
    _rz,
    value(0),
    wrap(_dodoes),
    value(@intFromEnum(Flag.IMMED)),
    value(@intFromEnum(Flag.HIDDEN)),
    value(F_LENMASK),
    value(@intFromEnum(syscalls.X64.exit)),
    value(@intFromEnum(syscalls.X64.open)),
    value(@intFromEnum(syscalls.X64.close)),
    value(@intFromEnum(syscalls.X64.read)),
    value(@intFromEnum(syscalls.X64.write)),
    value(@intFromEnum(syscalls.X64.creat)),
    value(@intFromEnum(syscalls.X64.brk)),
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
    wrap(_dspfetch),
    wrap(_dspstore),
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
    wrap(_hidden),
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

const immediate: std.StaticStringMap(void) = .initComptime(.{
    .{ "[", {} },
    .{ "IMMEDIATE", {} },
    .{ ";", {} },
});

const Composite = std.StaticStringMap([]const []const u8);
const composite: Composite = .initComptime(.{
    .{ ">DFA", &.{ ">CFA", fmt.comptimePrint("{d}+", .{@sizeOf(usize)}), "EXIT" } },
    .{ "HIDE", &.{ "WORD", "FIND", "HIDDEN", "EXIT" } },
    .{ ":", &.{ "WORD", "CREATE", "'", "0", ",", "LATEST", "@", "HIDDEN", "]", "EXIT" } },
    .{ ";", &.{ "'", "EXIT", ",", "LATEST", "@", "HIDDEN", "[", "EXIT" } },
    .{ "QUIT", &.{ "R0", "RSP!", "INTERPRET", "BRANCH", fmt.comptimePrint("{d}", .{-@sizeOf(usize)}) } },
});

const names: [108][]const u8 = .{
    "DROP",
    "SWAP",
    "DUP",
    "OVER",
    "ROT",
    "-ROT",
    "2DROP",
    "2DUP",
    "2SWAP",
    "?DUP",
    "1+",
    "1-",
    fmt.comptimePrint("{d}+", .{@sizeOf(usize)}),
    fmt.comptimePrint("{d}-", .{@sizeOf(usize)}),
    "+",
    "-",
    "*",
    "/MOD",
    "=",
    "<>",
    "<",
    ">",
    "<=",
    ">=",
    "0=",
    "0<>",
    "0<",
    "0>",
    "0<=",
    "0>=",
    "AND",
    "OR",
    "XOR",
    "INVERT",
    "EXIT",
    "LIT",
    "!",
    "@",
    "+!",
    "-!",
    "C!",
    "C@",
    "C@C!",
    "CMOVE",
    "STATE",
    "HERE",
    "LATEST",
    "S0",
    "BASE",
    "(ARGC)",
    "VERSION",
    "R0",
    "DOCOL",
    "DODOES",
    "F_IMMED",
    "F_HIDDEN",
    "F_LENMASK",
    "SYS_EXIT",
    "SYS_OPEN",
    "SYS_CLOSE",
    "SYS_READ",
    "SYS_WRITE",
    "SYS_CREAT",
    "SYS_BRK",
    "O_RDONLY",
    "O_WRONLY",
    "O_RDWR",
    "O_CREAT",
    "O_EXCL",
    "O_TRUNC",
    "O_APPEND",
    "O_NONBLOCK",
    ">R",
    "R>",
    "RSP@",
    "RSP!",
    "RDROP",
    "DSP@",
    "DSP!",
    "KEY",
    "EMIT",
    "WORD",
    "NUMBER",
    "FIND",
    ">CFA",
    ">DFA",
    "CREATE",
    ",",
    "[",
    "]",
    "IMMEDIATE",
    "HIDDEN",
    "HIDE",
    ":",
    "'",
    ";",
    "BRANCH",
    "0BRANCH",
    "LITSTRING",
    "TELL",
    "INTERPRET",
    "QUIT",
    "CHAR",
    "EXECUTE",
    "SYSCALL3",
    "SYSCALL2",
    "SYSCALL1",
    "SYSCALL0",
};

fn computeOffsets(
    comptime names_: []const []const u8,
    comptime composite_: Composite,
) std.StaticStringMap([]const usize) {
    const size: isize = @sizeOf(usize);
    comptime var kvs: [names_.len + 2]struct { []const u8, usize } = undefined;
    comptime var here = 0;
    inline for (names_, 0..) |name, i| {
        here += offset;
        kvs[i] = .{ name, here * size };
        here += 1;
        if (comptime composite_.get(name)) |words|
            here += words.len;
    }
    kvs[names_.len] = .{ "0", 0 };
    kvs[names_.len + 1] = .{ fmt.comptimePrint("{d}", .{-size}), @bitCast(-size) };
    const offsets: std.StaticStringMap(usize) = .initComptime(kvs);

    comptime var word_kvs: [names_.len]struct { []const u8, []const usize } = undefined;
    inline for (names_, 0..) |name, i| {
        const words = composite_.get(name) orelse .{};
        var indices: [words.len]usize = undefined;
        inline for (words, 0..) |word, j|
            indices[j] = offsets.get(word) orelse unreachable;
        word_kvs[i] = .{ name, indices[0..] };
    }
    return .initComptime(word_kvs);
}

fn defwords(
    comptime names_: []const []const u8,
    comptime immediate_: std.StaticStringMap(void),
    comptime composite_: Composite,
) struct { [0x800000]u8, usize, usize } {
    comptime {
        const offsets = computeOffsets(names_, composite_);
        var latest = 0;
        var here = 0;
        var code = 1;
        var buf = mem.zeroes([0x800000]u8);
        const size = @sizeOf(usize);
        for (offsets.kvs.keys[0..offsets.kvs.len], offsets.kvs.values[0..offsets.kvs.len]) |key, val| {
            mem.writeInt(usize, buf[here .. here + size], latest, native_endian);
            latest = here;
            here += size;
            const len: u8 = @truncate(key.len);
            buf[here] = len | if (immediate_.has(key)) @intFromEnum(Flag.IMMED) else 0;
            here += 1;
            @memcpy(buf[here .. here + key.len], key);
            here += key.len;
            mem.writeInt(usize, buf[here .. here + size], if (val.len == 0) 0 else code, native_endian);
            here += size;
            for (val) |index| {
                mem.writeInt(usize, buf[here .. here + size], index, native_endian);
                here += size;
            }
            code += if (val.len == 0) 1 else 0;
        }
        const final = buf;
        const latest_ = latest;
        const here_ = here;
        return .{ final, latest_, here_ };
    }
}

fn run(reader: *std.Io.Reader, writer: *std.Io.Writer, argv: []const [*:0]const u8) void {
    const N = 0x20;
    var stack: [N]isize = undefined;
    const sp = stack[N..];
    var return_stack: [N][*]const Instr = undefined;
    const rsp = return_stack[N..];
    var memory, const latest, const here = comptime defwords(&names, immediate, composite);
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    var m: std.array_list.AlignedManaged(u8, .of(usize)) = .fromOwnedSlice(fba.allocator(), @alignCast(memory[0..here]));
    defer m.deinit();
    var env: Interp = .init(reader, writer, argv, sp, rsp, &m, latest);
    const target: [*]const Instr = @ptrCast(&(env.find("QUIT") orelse unreachable).code);
    const cold_start: [1]Instr = .{.{ .word = @intFromPtr(target) }};
    const ip: [*]const Instr = &cold_start;

    @call(.auto, primitive(target), .{ &env, sp, rsp, ip, target });
}

pub fn main(init: std.process.Init) callconv(conv) void {
    var stdin_buffer: [2048]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    run(&stdin_reader.interface, &stdout_writer.interface, init.minimal.args.vector);
}

fn forth(input: []const u8, expected: [:0]const u8) !void {
    var fixedReader: std.Io.Reader = .fixed(input);

    var actual = mem.zeroes([2048]u8);
    var fixedWriter: std.Io.Writer = .fixed(&actual);
    run(&fixedReader, &fixedWriter, &.{});
    try testing.expectEqualSlices(u8, expected, mem.sliceTo(actual[0..], 0));
}

test forth {
    // This is a stripped version of https://github.com/nornagon/jonesforth/blob/master/jonesforth.S
    // to bootstrap just enough "high-level" Forth so this test achieves reasonable coverage.
    const preamble = fmt.comptimePrint(
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
        \\: PICK 1+ {d} * DSP@ + @ ;
        \\: SPACES BEGIN DUP 0> WHILE SPACE 1- REPEAT DROP ;
        \\: U. BASE @ /MOD ?DUP IF RECURSE THEN DUP 10 < IF '0' ELSE 10 - 'A' THEN + EMIT ;
        \\: .S DSP@ BEGIN DUP S0 @ < WHILE DUP @ U. {d}+ SPACE REPEAT DROP ;
        \\: UWIDTH BASE @ / ?DUP IF RECURSE 1+ ELSE 1 THEN ;
        \\: U.R SWAP DUP UWIDTH ROT SWAP - SPACES U. ;
        \\: .R SWAP DUP 0< IF NEGATE 1 SWAP ROT 1- ELSE 0 SWAP ROT THEN SWAP DUP UWIDTH ROT SWAP - SPACES SWAP IF '-' EMIT THEN U. ;
        \\: . 0 .R SPACE ;
        \\: U. U. SPACE ;
        \\: WITHIN -ROT OVER <= IF > IF TRUE ELSE FALSE THEN ELSE 2DROP FALSE THEN ;
        \\: ALIGNED {d} 1- + -{d} AND ;
        \\: ALIGN HERE @ ALIGNED HERE ! ;
        \\: C, HERE @ C! 1 HERE +! ;
        \\: S" IMMEDIATE STATE @ IF
        \\  ' LITSTRING , HERE @ 0 , BEGIN KEY DUP '"' <> WHILE C, REPEAT DROP DUP HERE @ SWAP - {d}- SWAP ! ALIGN ELSE
        \\  HERE @ BEGIN KEY DUP '"' <> WHILE OVER C! 1+ REPEAT DROP HERE @ - HERE @ SWAP THEN ;
        \\: ." IMMEDIATE STATE @ IF [COMPILE] S" ' TELL , ELSE BEGIN KEY DUP '"' = IF DROP EXIT THEN EMIT AGAIN THEN ;
        \\: CELLS {d} * ;
        \\: ID. {d}+ DUP C@ F_LENMASK AND BEGIN DUP 0> WHILE SWAP 1+ DUP C@ EMIT SWAP 1- REPEAT 2DROP ;
        \\: ?IMMEDIATE {d}+ C@ F_IMMED AND ;
        \\: CASE    IMMEDIATE 0 ;
        \\: OF      IMMEDIATE ' OVER , ' = , [COMPILE] IF ' DROP , ;
        \\: ENDOF   IMMEDIATE [COMPILE] ELSE ;
        \\: ENDCASE IMMEDIATE ' DROP , BEGIN ?DUP WHILE [COMPILE] THEN REPEAT ;
        \\: CFA> LATEST @ BEGIN ?DUP WHILE 2DUP SWAP < IF NIP EXIT THEN @ REPEAT DROP 0 ;
        \\: SEE WORD FIND HERE @ LATEST @ BEGIN 2 PICK OVER <> WHILE NIP DUP @ REPEAT DROP SWAP
        \\  ':' EMIT SPACE DUP ID. SPACE DUP ?IMMEDIATE IF ." IMMEDIATE " THEN >DFA
        \\  BEGIN 2DUP > WHILE DUP @
        \\      CASE
        \\          ' LIT OF {d}+ DUP @ . ENDOF
        \\          ' LITSTRING OF [ CHAR S ] LITERAL EMIT '"' EMIT SPACE {d}+ DUP @ SWAP {d}+ SWAP 2DUP TELL '"' EMIT SPACE + ALIGNED {d}- ENDOF
        \\          ' 0BRANCH OF ." 0BRANCH ( " {d}+ DUP @ . ." ) " ENDOF
        \\          '  BRANCH OF  ." BRANCH ( " {d}+ DUP @ . ." ) " ENDOF
        \\          ' ' OF [ CHAR ' ] LITERAL EMIT SPACE {d}+ DUP CFA> ID. SPACE ENDOF
        \\          ' EXIT OF 2DUP {d}+ <> IF ." EXIT " THEN ENDOF
        \\          DUP CFA> ID. SPACE
        \\      ENDCASE
        \\      {d}+
        \\  REPEAT
        \\ ';' EMIT CR 2DROP ;
        \\: ['] IMMEDIATE ' LIT , ;
        \\: EXCEPTION-MARKER RDROP 0 ;
        \\: CATCH DSP@ {d}+ >R ' EXCEPTION-MARKER {d}+ >R EXECUTE ;
        \\: THROW ?DUP IF RSP@ BEGIN DUP R0 {d}- < WHILE DUP @ ' EXCEPTION-MARKER {d}+ = IF {d}+ RSP! DUP DUP DUP R> {d}- SWAP OVER ! DSP! EXIT THEN {d}+ REPEAT
        \\  DROP CASE 0 1- OF ." ABORTED" CR ENDOF ." UNCAUGHT THROW " DUP . CR ENDCASE QUIT THEN ;
        \\: STRLEN DUP BEGIN DUP C@ 0<> WHILE 1+ REPEAT SWAP - ;
        \\ 
    , .{@sizeOf(usize)} ** 24);

    const s = mem.readInt(usize, "F" ** @sizeOf(usize), .little);
    const tests = .{
        .{ "65 EMIT ", "A" },
        .{ "777 65 EMIT ", "A" },
        .{ "32 DUP + 1+ EMIT ", "A" },
        .{ "16 DUP 2DUP + + + 1+ EMIT ", "A" },
        .{ "8 DUP * 1+ EMIT ", "A" },
        .{ "CHAR A EMIT ", "A" },
        .{ ": SLOW WORD FIND >CFA EXECUTE ; 65 SLOW EMIT ", "A" },
        .{ fmt.comptimePrint("{d} DSP@ {d} TELL ", .{ s, @sizeOf(usize) }), "F" ** @sizeOf(usize) },
        .{ fmt.comptimePrint("{d} DSP@ HERE @ {d} CMOVE HERE @ {d} TELL ", .{ s, @sizeOf(usize), @sizeOf(usize) }), "F" ** @sizeOf(usize) },
        .{ fmt.comptimePrint("{d} DSP@ 2 NUMBER DROP EMIT ", .{mem.readInt(u16, "65", .little)}), "A" },
        .{ "64 >R RSP@ 1 TELL RDROP ", "@" },
        .{ "64 DSP@ RSP@ SWAP C@C! RSP@ 1 TELL ", "@" },
        .{ "64 >R 1 RSP@ +! RSP@ 1 TELL ", "A" },
        .{
            \\: <BUILDS WORD CREATE DODOES , 0 , ;
            \\: DOES> R> LATEST @ >DFA ! ;
            \\: CONST <BUILDS , DOES> @ ;
            \\
            \\65 CONST FOO
            \\FOO EMIT 
            ,
            "A",
        },
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
        .{ preamble ++ "SEE >DFA ", fmt.comptimePrint(": >DFA >CFA {d}+ EXIT ;\n", .{@sizeOf(usize)}) },
        .{ preamble ++ "SEE HIDE ", ": HIDE WORD FIND HIDDEN ;\n" },
        .{ preamble ++ "SEE QUIT ", fmt.comptimePrint(": QUIT R0 RSP! INTERPRET BRANCH ( -{d} ) ;\n", .{2 * @sizeOf(usize)}) },
        .{ preamble ++ "SEE / ", ": / /MOD SWAP DROP ;\n" },
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
        const p = try fmt.allocPrintSentinel(testing.allocator, "{d} ", .{os.linux.getppid()}, 0);
        defer testing.allocator.free(p);

        try forth(preamble ++ ": ARGC (ARGC) @ ; ARGC . ", "4 ");
        try forth(preamble ++ ": ARGC (ARGC) @ ; : ENVIRON ARGC 2 + CELLS (ARGC) + ; ENVIRON @ DUP STRLEN TELL ", mem.sliceTo(testing.environ.block.view().slice[0], 0));
        try forth(preamble ++ fmt.comptimePrint(": GETPPID {d} SYSCALL0 ; GETPPID . ", .{@intFromEnum(syscalls.X64.getppid)}), p);
    }
}
