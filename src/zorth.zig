const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const syscalls = os.linux.syscalls;
const arch = @import("builtin").cpu.arch;

const conv: std.builtin.CallingConvention = switch (arch) {
    .x86_64 => .winapi,
    else => .auto,
};
var stdin_buffer: [2048]u8 = undefined;
var stdin_reader = fs.File.stdin().reader(&stdin_buffer);
const stdin = &stdin_reader.interface;

var stdout_buffer: [2048]u8 = undefined;
var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

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

const Word = extern struct {
    link: ?*const Word,
    flag: u8,
    name: [F_LENMASK]u8 align(1),
};

const offset = @divExact(@sizeOf(Word), @sizeOf(Instr));

inline fn codeFieldAddress(w: [*]const Instr) [*]const Instr {
    return w + offset;
}

fn InterpAligned(comptime alignment: mem.Alignment) type {
    return struct {
        const Self = @This();

        state: isize,
        latest: *Word,
        s0: [*]const isize,
        base: isize,
        r0: [*]const [*]const Instr,
        buffer: [32]u8,
        memory: *std.array_list.AlignedManaged(u8, alignment),
        here: [*]u8,

        pub fn init(sp: []const isize, rsp: []const [*]const Instr, m: *std.array_list.AlignedManaged(u8, alignment)) Self {
            m.ensureUnusedCapacity(@sizeOf(Instr)) catch @panic("init cannot ensureUnusedCapacity");
            return .{
                .state = 0,
                .latest = @ptrCast(&syscall0),
                .s0 = sp.ptr,
                .base = 10,
                .r0 = rsp.ptr,
                .buffer = undefined,
                .memory = m,
                .here = m.items.ptr + m.items.len,
            };
        }

        pub inline fn next(self: *Self, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) void {
            _ = target;
            const tgt = ip[0].word;
            return @call(.always_tail, tgt[0].code, .{ self, sp, rsp, ip[1..], tgt });
        }

        pub fn word(self: *Self) usize {
            var ch: u8 = std.ascii.control_code.nul;
            var i: usize = 0;

            while (ch <= ' ') {
                ch = key();
                if (ch == '\\') { // comment ⇒ skip line
                    while (ch != '\n') ch = key();
                }
            }
            while (ch > ' ') {
                self.buffer[i] = ch;
                i += 1;
                ch = key();
            }
            return i;
        }

        pub fn find(self: Self, name: []u8) ?*const Word {
            const mask = @intFromEnum(Flag.HIDDEN) | F_LENMASK;
            var node: ?*const Word = self.latest;
            while (node != null and ((node.?.flag & mask) != name.len or !mem.eql(u8, node.?.name[0..name.len], name)))
                node = node.?.link;

            return node;
        }

        pub fn append(self: *Self, instr: Instr) void {
            self.memory.items.len = @intFromPtr(self.here) - @intFromPtr(self.memory.items.ptr);
            self.memory.appendSlice(mem.asBytes(&instr)) catch @panic("append cannot appendSlice");
            self.here = self.memory.items.ptr + self.memory.items.len;
        }
    };
}

const Interp = InterpAligned(mem.Alignment.of(Instr));

const Instr = packed union {
    code: *const fn (*Interp, [*]isize, [*][*]const Instr, [*]const Instr, [*]const Instr) callconv(conv) void,
    literal: isize,
    word: [*]const Instr,
};

const Source = union(enum) {
    self: []const u8,
    literal: isize,
};

fn key() u8 {
    const b = stdin.takeByte() catch std.process.exit(0);
    return b;
}

fn defword_(
    comptime last: ?[]const Instr,
    comptime flag: Flag,
    comptime name: []const u8,
    comptime code: []const Instr,
) [offset + code.len]Instr {
    var instrs: [offset + code.len]Instr = undefined;
    const p: *Word = @ptrCast(&instrs[0]);
    p.link = if (last == null) null else @ptrCast(last.?.ptr);
    p.flag = name.len | @intFromEnum(flag);
    @memcpy(p.name[0..name.len], name);
    @memset(p.name[name.len..F_LENMASK], 0);
    @memcpy(instrs[offset..], code);
    return instrs;
}

fn defcode_(
    comptime last: ?[]const Instr,
    comptime name: []const u8,
    comptime code: fn (*Interp, [*]isize, [*][*]const Instr, [*]const Instr, [*]const Instr) callconv(conv) void,
) [offset + 1]Instr {
    return defword_(last, Flag.ZERO, name, &.{.{ .code = code }});
}

fn defcode(
    comptime last: ?[]const Instr,
    comptime name: []const u8,
    comptime stack: fn ([*]isize) callconv(.@"inline") [*]isize,
) [offset + 1]Instr {
    const wrap = struct {
        pub fn code(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
            self.next(stack(sp), rsp, ip, target);
        }
    };
    return defcode_(last, name, wrap.code);
}

fn defconst(
    comptime last: ?[]const Instr,
    comptime name: []const u8,
    comptime value: Source,
) [offset + 1]Instr {
    const wrap = struct {
        pub fn code(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
            const s = sp - 1;
            s[0] = switch (value) {
                .self => |f| @intCast(@intFromPtr(&@field(self, f))),
                .literal => |i| i,
            };
            self.next(s, rsp, ip, target);
        }
    };
    return defcode_(last, name, wrap.code);
}

fn defword(
    comptime last: ?[]const Instr,
    comptime flag: Flag,
    comptime name: []const u8,
    comptime data: []const []const Instr,
) [offset + data.len + 1]Instr {
    var code: [data.len + 1]Instr = undefined;
    code[0].code = docol_;
    inline for (code[1..], data) |*d, s|
        d.word = codeFieldAddress(s.ptr);
    return defword_(last, flag, name, code[0..]);
}

inline fn _drop(sp: [*]isize) [*]isize {
    return sp[1..];
}
const drop = defcode(null, "DROP", _drop);

inline fn _swap(sp: [*]isize) [*]isize {
    const temp = sp[1];
    sp[1] = sp[0];
    sp[0] = temp;
    return sp;
}
const swap = defcode(&drop, "SWAP", _swap);

inline fn _dup(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = sp[0];
    return s;
}
const dup = defcode(&swap, "DUP", _dup);

inline fn _over(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = sp[1];
    return s;
}
const over = defcode(&dup, "OVER", _over);

inline fn _rot(sp: [*]isize) [*]isize {
    const a = sp[0];
    const b = sp[1];
    const c = sp[2];
    sp[2] = b;
    sp[1] = a;
    sp[0] = c;
    return sp;
}
const rot = defcode(&over, "ROT", _rot);

inline fn _nrot(sp: [*]isize) [*]isize {
    const a = sp[0];
    const b = sp[1];
    const c = sp[2];
    sp[2] = a;
    sp[1] = c;
    sp[0] = b;
    return sp;
}
const nrot = defcode(&rot, "-ROT", _nrot);

inline fn _twodrop(sp: [*]isize) [*]isize {
    return sp[2..];
}
const twodrop = defcode(&nrot, "2DROP", _twodrop);

inline fn _twodup(sp: [*]isize) [*]isize {
    const s = sp - 2;
    s[1] = sp[1];
    s[0] = sp[0];
    return s;
}
const twodup = defcode(&twodrop, "2DUP", _twodup);

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
const twoswap = defcode(&twodup, "2SWAP", _twoswap);

inline fn _qdup(sp: [*]isize) [*]isize {
    if (sp[0] != 0) {
        const s = sp - 1;
        s[0] = sp[0];
        return s;
    }
    return sp;
}
const qdup = defcode(&twoswap, "?DUP", _qdup);

inline fn _incr(sp: [*]isize) [*]isize {
    sp[0] += 1;
    return sp;
}
const incr = defcode(&qdup, "1+", _incr);

inline fn _decr(sp: [*]isize) [*]isize {
    sp[0] -= 1;
    return sp;
}
const decr = defcode(&incr, "1-", _decr);

inline fn _incrp(sp: [*]isize) [*]isize {
    sp[0] += @sizeOf(usize);
    return sp;
}
const incrp = defcode(&decr, fmt.comptimePrint("{d}+", .{@sizeOf(usize)}), _incrp);

inline fn _decrp(sp: [*]isize) [*]isize {
    sp[0] -= @sizeOf(usize);
    return sp;
}
const decrp = defcode(&incrp, fmt.comptimePrint("{d}-", .{@sizeOf(usize)}), _decrp);

inline fn _add(sp: [*]isize) [*]isize {
    sp[1] += sp[0];
    return sp[1..];
}
const add = defcode(&decrp, "+", _add);

inline fn _sub(sp: [*]isize) [*]isize {
    sp[1] -= sp[0];
    return sp[1..];
}
const sub = defcode(&add, "-", _sub);

inline fn _mul(sp: [*]isize) [*]isize {
    sp[1] *= sp[0];
    return sp[1..];
}
const mul = defcode(&sub, "*", _mul);

inline fn _divmod(sp: [*]isize) [*]isize {
    const a = sp[1];
    const b = sp[0];
    sp[1] = @rem(a, b);
    sp[0] = @divTrunc(a, b);
    return sp;
}
const divmod = defcode(&mul, "/MOD", _divmod);

inline fn _equ(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] == sp[0]) -1 else 0;
    return sp[1..];
}
const equ = defcode(&divmod, "=", _equ);

inline fn _nequ(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] == sp[0]) 0 else -1;
    return sp[1..];
}
const nequ = defcode(&equ, "<>", _nequ);

inline fn _lt(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] < sp[0]) -1 else 0;
    return sp[1..];
}
const lt = defcode(&nequ, "<", _lt);

inline fn _gt(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] > sp[0]) -1 else 0;
    return sp[1..];
}
const gt = defcode(&lt, ">", _gt);

inline fn _le(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] <= sp[0]) -1 else 0;
    return sp[1..];
}
const le = defcode(&gt, "<=", _le);

inline fn _ge(sp: [*]isize) [*]isize {
    sp[1] = if (sp[1] >= sp[0]) -1 else 0;
    return sp[1..];
}
const ge = defcode(&le, ">=", _ge);

inline fn _zequ(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] == 0) -1 else 0;
    return sp;
}
const zequ = defcode(&ge, "0=", _zequ);

inline fn _znequ(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] != 0) -1 else 0;
    return sp;
}
const znequ = defcode(&zequ, "0<>", _znequ);

inline fn _zlt(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] < 0) -1 else 0;
    return sp;
}
const zlt = defcode(&znequ, "0<", _zlt);

inline fn _zgt(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] > 0) -1 else 0;
    return sp;
}
const zgt = defcode(&zlt, "0>", _zgt);

inline fn _zle(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] <= 0) -1 else 0;
    return sp;
}
const zle = defcode(&zgt, "0<=", _zle);

inline fn _zge(sp: [*]isize) [*]isize {
    sp[0] = if (sp[0] >= 0) -1 else 0;
    return sp;
}
const zge = defcode(&zle, "0>=", _zge);

inline fn _and(sp: [*]isize) [*]isize {
    sp[1] &= sp[0];
    return sp[1..];
}
const and_ = defcode(&zge, "AND", _and);

inline fn _or(sp: [*]isize) [*]isize {
    sp[1] |= sp[0];
    return sp[1..];
}
const or_ = defcode(&and_, "OR", _or);

inline fn _xor(sp: [*]isize) [*]isize {
    sp[1] ^= sp[0];
    return sp[1..];
}
const xor = defcode(&or_, "XOR", _xor);

inline fn _invert(sp: [*]isize) [*]isize {
    sp[0] = ~sp[0];
    return sp;
}
const invert = defcode(&xor, "INVERT", _invert);

fn _exit(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    _ = ip;
    self.next(sp, rsp[1..], rsp[0], target);
}
const exit = defcode_(&invert, "EXIT", _exit);

fn _lit(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    s[0] = ip[0].literal;
    self.next(s, rsp, ip[1..], target);
}
const lit = defcode_(&exit, "LIT", _lit);

inline fn _store(sp: [*]isize) [*]isize {
    const p: *isize = @ptrFromInt(@abs(sp[0]));
    p.* = sp[1];
    return sp[2..];
}
const store = defcode(&lit, "!", _store);

inline fn _fetch(sp: [*]isize) [*]isize {
    const p: *isize = @ptrFromInt(@abs(sp[0]));
    sp[0] = p.*;
    return sp;
}
const fetch = defcode(&store, "@", _fetch);

inline fn _addstore(sp: [*]isize) [*]isize {
    const p: *[*]u8 = @ptrFromInt(@abs(sp[0]));
    p.* += @abs(sp[1]);
    return sp[2..];
}
const addstore = defcode(&fetch, "+!", _addstore);

inline fn _substore(sp: [*]isize) [*]isize {
    const p: *[*]u8 = @ptrFromInt(@abs(sp[0]));
    p.* -= @abs(sp[1]);
    return sp[2..];
}
const substore = defcode(&addstore, "-!", _substore);

inline fn _storebyte(sp: [*]isize) [*]isize {
    const p: [*]u8 = @ptrFromInt(@abs(sp[0]));
    const v: u8 = @truncate(@abs(sp[1]));
    p[0] = v;
    return sp[2..];
}
const storebyte = defcode(&substore, "C!", _storebyte);

inline fn _fetchbyte(sp: [*]isize) [*]isize {
    const p: [*]u8 = @ptrFromInt(@abs(sp[0]));
    sp[0] = p[0];
    return sp;
}
const fetchbyte = defcode(&storebyte, "C@", _fetchbyte);

inline fn _ccopy(sp: [*]isize) [*]isize {
    const p: [*]u8 = @ptrFromInt(@abs(sp[0]));
    const q: [*]u8 = @ptrFromInt(@abs(sp[1]));
    q[0] = p[0];
    return sp[2..];
}
const ccopy = defcode(&fetchbyte, "C@C!", _ccopy);

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
const cmove = defcode(&ccopy, "CMOVE", _cmove);
const state = defconst(&cmove, "STATE", .{ .self = "state" });

fn _here(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    self.memory.ensureUnusedCapacity(@sizeOf(Instr)) catch @panic("_here cannot ensureUnusedCapacity");
    s[0] = @intCast(@intFromPtr(&self.here));
    self.next(s, rsp, ip, target);
}
const here = defcode_(&state, "HERE", _here);
const latest = defconst(&here, "LATEST", .{ .self = "latest" });
const sz = defconst(&latest, "S0", .{ .self = "s0" });
const base = defconst(&sz, "BASE", .{ .self = "base" });

inline fn _argc(sp: [*]isize) [*]isize {
    const s = sp - 1;
    const u = @intFromPtr(os.argv.ptr - 1);
    s[0] = @intCast(u);
    return s;
}
const argc = defcode(&base, "(ARGC)", _argc);
const version = defconst(&if (arch.isWasm()) base else argc, "VERSION", .{ .literal = 47 });

fn _rz(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    const u = @intFromPtr(self.r0);
    s[0] = @intCast(u);
    self.next(s, rsp, ip, target);
}
const rz = defcode_(&version, "R0", _rz);

fn docol_(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const r = rsp - 1;
    r[0] = ip;
    self.next(sp, r, target[1..], target);
}

inline fn _docol(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(&docol_));
    return s;
}
const docol = defcode(&rz, "DOCOL", _docol);

fn dodoes_(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const r = rsp - 1;
    const s = sp - 1;
    r[0] = ip;
    s[0] = @intCast(@intFromPtr(&target[2]));
    self.next(s, r, target[1].word, target);
}

inline fn _dodoes(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(&dodoes_));
    return s;
}
const dodoes = defcode(&docol, "DODOES", _dodoes);
const f_immed = defconst(&dodoes, "F_IMMED", .{ .literal = @intFromEnum(Flag.IMMED) });
const f_hidden = defconst(&f_immed, "F_HIDDEN", .{ .literal = @intFromEnum(Flag.HIDDEN) });
const f_lenmask = defconst(&f_hidden, "F_LENMASK", .{ .literal = F_LENMASK });
const sys_exit = defconst(&f_lenmask, "SYS_EXIT", .{ .literal = @intFromEnum(syscalls.X64.exit) });
const sys_open = defconst(&sys_exit, "SYS_OPEN", .{ .literal = @intFromEnum(syscalls.X64.open) });
const sys_close = defconst(&sys_open, "SYS_CLOSE", .{ .literal = @intFromEnum(syscalls.X64.close) });
const sys_read = defconst(&sys_close, "SYS_READ", .{ .literal = @intFromEnum(syscalls.X64.read) });
const sys_write = defconst(&sys_read, "SYS_WRITE", .{ .literal = @intFromEnum(syscalls.X64.write) });
const sys_creat = defconst(&sys_write, "SYS_CREAT", .{ .literal = @intFromEnum(syscalls.X64.creat) });
const sys_brk = defconst(&sys_creat, "SYS_BRK", .{ .literal = @intFromEnum(syscalls.X64.brk) });
const o_rdonly = defconst(&sys_brk, "O_RDONLY", .{ .literal = O_RDONLY });
const o_wronly = defconst(&o_rdonly, "O_WRONLY", .{ .literal = O_WRONLY });
const o_rdwr = defconst(&o_wronly, "O_RDWR", .{ .literal = O_RDWR });
const o_creat = defconst(&o_rdwr, "O_CREAT", .{ .literal = O_CREAT });
const o_excl = defconst(&o_creat, "O_EXCL", .{ .literal = O_EXCL });
const o_trunc = defconst(&o_excl, "O_TRUNC", .{ .literal = O_TRUNC });
const o_append = defconst(&o_trunc, "O_APPEND", .{ .literal = O_APPEND });
const o_nonblock = defconst(&o_append, "O_NONBLOCK", .{ .literal = O_NONBLOCK });

fn _tor(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const r = rsp - 1;
    const t: [*]Instr = @ptrFromInt(@abs(sp[0]));
    r[0] = t;
    self.next(sp[1..], r, ip, target);
}
const tor = defcode_(&o_nonblock, ">R", _tor);

fn _fromr(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(rsp[0]));
    self.next(s, rsp[1..], ip, target);
}
const fromr = defcode_(&tor, "R>", _fromr);

fn _rspfetch(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(rsp));
    self.next(s, rsp, ip, target);
}
const rspfetch = defcode_(&fromr, "RSP@", _rspfetch);

fn _rspstore(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    _ = rsp;
    const s = @abs(sp[0]);
    const t: [*][*]const Instr = @ptrFromInt(s);
    self.next(sp[1..], t, ip, target);
}
const rspstore = defcode_(&rspfetch, "RSP!", _rspstore);

fn _rdrop(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    self.next(sp, rsp[1..], ip, target);
}
const rdrop = defcode_(&rspstore, "RDROP", _rdrop);

inline fn _dspfetch(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = @intCast(@intFromPtr(sp));
    return s;
}
const dspfetch = defcode(&rdrop, "DSP@", _dspfetch);

inline fn _dspstore(sp: [*]isize) [*]isize {
    const u = @abs(sp[0]);
    const p: [*]isize = @ptrFromInt(u);
    return p;
}
const dspstore = defcode(&dspfetch, "DSP!", _dspstore);

inline fn _key(sp: [*]isize) [*]isize {
    const s = sp - 1;
    s[0] = @intCast(key());
    return s;
}
const key_ = defcode(&dspstore, "KEY", _key);

inline fn _emit(sp: [*]isize) [*]isize {
    const c: u8 = @truncate(@abs(sp[0]));
    stdout.print("{c}", .{c}) catch {};
    stdout.flush() catch {};
    return sp[1..];
}
const emit = defcode(&key_, "EMIT", _emit);

fn _word(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 2;
    const u = @intFromPtr(&self.buffer);
    s[1] = @intCast(u);
    s[0] = @intCast(self.word());
    self.next(s, rsp, ip, target);
}
const word_ = defcode_(&emit, "WORD", _word);

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
const number = defcode_(&word_, "NUMBER", _number);

fn _find(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s: [*]u8 = @ptrFromInt(@abs(sp[1]));
    const v = self.find(s[0..@abs(sp[0])]);

    sp[1] = @intCast(@intFromPtr(v));
    self.next(sp[1..], rsp, ip, target);
}
const find_ = defcode_(&number, "FIND", _find);

inline fn _tcfa(sp: [*]isize) [*]isize {
    const w: [*]const Instr = @ptrFromInt(@abs(sp[0]));
    sp[0] = @intCast(@intFromPtr(codeFieldAddress(w)));
    return sp;
}
const tcfa = defcode(&find_, ">CFA", _tcfa);
const tdfa = defword(
    &tcfa,
    Flag.ZERO,
    ">DFA",
    &.{ &tcfa, &incrp, &exit, &exit },
);

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
const create = defcode_(&tdfa, "CREATE", _create);

fn _comma(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s: isize = sp[0];
    const instr: Instr = if (s < 0x1000) .{ .literal = s } else if (s == @intFromPtr(&docol_)) .{ .code = docol_ } else .{ .word = blk: {
        const p: [*]const Instr = @ptrFromInt(@abs(s));
        break :blk p;
    } };
    self.append(instr);
    self.next(sp[1..], rsp, ip, target);
}
const comma = defcode_(&create, ",", _comma);

fn _lbrac(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    self.state = 0;
    self.next(sp, rsp, ip, target);
}
const lbrac = defword_(
    &comma,
    Flag.IMMED,
    "[",
    &.{.{ .code = _lbrac }},
);

fn _rbrac(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    self.state = 1;
    self.next(sp, rsp, ip, target);
}
const rbrac = defcode_(&lbrac, "]", _rbrac);

fn _immediate(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    self.latest.flag ^= @intFromEnum(Flag.IMMED);
    self.next(sp, rsp, ip, target);
}
const immediate = defword_(
    &rbrac,
    Flag.IMMED,
    "IMMEDIATE",
    &.{.{ .code = _immediate }},
);

inline fn _hidden(sp: [*]isize) [*]isize {
    const w: *Word = @ptrFromInt(@abs(sp[0]));
    w.flag ^= @intFromEnum(Flag.HIDDEN);
    return sp[1..];
}
const hidden = defcode(&immediate, "HIDDEN", _hidden);
const hide = defword(
    &hidden,
    Flag.ZERO,
    "HIDE",
    &.{ &word_, &find_, &hidden, &exit },
);
const colon = defword(
    &hide,
    Flag.ZERO,
    ":",
    &.{ &word_, &create, &docol, &comma, &latest, &fetch, &hidden, &rbrac, &exit, &exit },
);

fn _tick(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    const u = @intFromPtr(ip[0].word);
    s[0] = @intCast(u);
    self.next(s, rsp, ip[1..], target);
}
const tick = defcode_(&colon, "'", _tick);
const semicolon = defword(
    &tick,
    Flag.IMMED,
    ";",
    &.{ &tick, &exit, &comma, &latest, &fetch, &hidden, &lbrac, &exit },
);

fn _branch(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const n = @divTrunc(ip[0].literal, @sizeOf(Instr));
    const a = @abs(n);
    const p = if (n < 0) ip - a else ip + a;
    self.next(sp, rsp, p, target);
}
const branch = defcode_(&semicolon, "BRANCH", _branch);

fn _zbranch(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    if (sp[0] == 0)
        return @call(.always_tail, _branch, .{ self, sp[1..], rsp, ip, target });
    self.next(sp[1..], rsp, ip[1..], target);
}
const zbranch = defcode_(&branch, "0BRANCH", _zbranch);

fn _litstring(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const c = @abs(ip[0].literal);
    const s = sp - 2;
    s[1] = @intCast(@intFromPtr(&ip[1]));
    s[0] = @intCast(c);
    const n = @abs(1 + @divTrunc(c + @sizeOf(Instr), @sizeOf(Instr)));
    self.next(s, rsp, ip[n..], target);
}
const litstring = defcode_(&zbranch, "LITSTRING", _litstring);

inline fn _tell(sp: [*]isize) [*]isize {
    const p: [*]u8 = @ptrFromInt(@abs(sp[1]));
    _ = stdout.write(p[0..@abs(sp[0])]) catch -1;
    stdout.flush() catch {};
    return sp[2..];
}
const tell = defcode(&litstring, "TELL", _tell);

fn _interpret(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const c = self.word();
    var s = sp;

    if (self.find(self.buffer[0..c])) |new| {
        const tgt = codeFieldAddress(@ptrCast(new));
        if ((new.flag & @intFromEnum(Flag.IMMED)) != 0 or self.state == 0) {
            return @call(.always_tail, tgt[0].code, .{ self, sp, rsp, ip, tgt });
        } else {
            self.append(.{ .word = tgt });
        }
    } else if (fmt.parseInt(isize, self.buffer[0..c], @truncate(@abs(self.base)))) |a| {
        if (self.state == 1) {
            self.append(.{ .word = codeFieldAddress(&lit) });
            self.append(.{ .literal = a });
        } else {
            s = sp - 1;
            s[0] = a;
        }
    } else |_| {
        std.debug.print("PARSE ERROR: {s}\n", .{self.buffer[0..c]});
        std.process.exit(0);
    }
    self.next(s, rsp, ip, target);
}
const interpret = defcode_(&tell, "INTERPRET", _interpret);
const _quit: [7]Instr = .{
    .{ .code = docol_ },
    .{ .word = codeFieldAddress(&rz) },
    .{ .word = codeFieldAddress(&rspstore) },
    .{ .word = codeFieldAddress(&interpret) },
    .{ .word = codeFieldAddress(&branch) },
    .{ .literal = -2 * @sizeOf(Instr) },
    .{ .word = codeFieldAddress(&exit) },
};
const quit = defword_(&interpret, Flag.ZERO, "QUIT", &_quit);

fn _char(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const s = sp - 1;
    _ = self.word();
    s[0] = self.buffer[0];
    self.next(s, rsp, ip, target);
}
const char = defcode_(&quit, "CHAR", _char);

fn _execute(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    _ = target;
    const target_: *Instr = @ptrFromInt(@abs(sp[0]));
    return @call(.always_tail, target_.code, .{ self, sp[1..], rsp, ip, target_[0..0] });
}
const execute = defcode_(&char, "EXECUTE", _execute);

inline fn _syscall3(sp: [*]isize) [*]isize {
    const number_: syscalls.X64 = @enumFromInt(sp[0]);

    switch (number_) {
        .open => {
            const p: usize = @intCast(sp[1]);
            const file_path: [*:0]u8 = @ptrFromInt(p);
            const flags: u32 = @intCast(sp[2]);
            const perm: fs.File.Mode = @intCast(sp[3]);
            sp[3] = if (fs.cwd().createFileZ(file_path, .{
                .read = (flags & (O_RDONLY | O_RDWR)) != 0,
                .truncate = (flags & O_TRUNC) != 0,
                .exclusive = (flags & O_EXCL) != 0,
                .lock_nonblocking = (flags & O_NONBLOCK) != 0,
                .mode = perm,
            })) |file| @intCast(file.handle) else |_| -1;
        },
        .read => {
            const file: fs.File = .{ .handle = @intCast(sp[1]) };
            const p: usize = @intCast(sp[2]);
            const buf: [*]u8 = @ptrFromInt(p);
            const n: usize = @intCast(sp[3]);
            sp[3] = if (file.read(buf[0..n])) |m| @intCast(m) else |_| -1;
        },
        .write => {
            const file: fs.File = .{ .handle = @intCast(sp[1]) };
            const p: usize = @intCast(sp[2]);
            const buf: [*]u8 = @ptrFromInt(p);
            const n: usize = @intCast(sp[3]);
            sp[3] = if (file.write(buf[0..n])) |m| @intCast(m) else |_| -1;
        },
        else => {},
    }
    return sp[3..];
}
const syscall3 = defcode(&execute, "SYSCALL3", _syscall3);

inline fn _syscall2(sp: [*]isize) [*]isize {
    const number_: syscalls.X64 = @enumFromInt(sp[0]);

    switch (number_) {
        .open => {
            const p: usize = @intCast(sp[1]);
            const file_path: [*:0]u8 = @ptrFromInt(p);
            const flags: u32 = @intCast(sp[2]);
            sp[2] = if (fs.cwd().openFileZ(file_path, .{
                .mode = @enumFromInt(flags & (O_RDONLY | O_WRONLY | O_RDWR)),
                .lock_nonblocking = (flags & O_NONBLOCK) != 0,
            })) |file| @intCast(file.handle) else |_| -1;
        },
        else => {},
    }
    return sp[2..];
}
const syscall2 = defcode(&syscall3, "SYSCALL2", _syscall2);

fn _syscall1(self: *Interp, sp: [*]isize, rsp: [*][*]const Instr, ip: [*]const Instr, target: [*]const Instr) callconv(conv) void {
    const number_: syscalls.X64 = @enumFromInt(sp[0]);

    switch (number_) {
        .exit => {
            const status: u8 = @truncate(@abs(sp[1]));
            std.process.exit(status);
        },
        .close => {
            const file: fs.File = .{ .handle = @intCast(sp[1]) };
            file.close();
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
const syscall1 = defcode_(&syscall2, "SYSCALL1", _syscall1);

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
var syscall0 = defcode(&syscall1, "SYSCALL0", _syscall0);

var memory: [0x800000]u8 linksection(".bss") = undefined;

pub fn main() callconv(conv) void {
    const N = 0x20;
    var stack: [N]isize = undefined;
    const sp = stack[N..];
    var return_stack: [N][*]const Instr = undefined;
    const rsp = return_stack[N..];
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    var m: std.array_list.AlignedManaged(u8, mem.Alignment.of(Instr)) = .init(fba.allocator());
    defer m.deinit();
    var env: Interp = .init(sp, rsp, &m);
    const target = &_quit;
    const cold_start: [1]Instr = .{.{ .word = target }};
    const ip: [*]const Instr = &cold_start;

    target[0].code(&env, sp, rsp, ip, target);
}

fn mainWithoutEnv(c_argc: c_int, c_argv: [*][*:0]c_char) callconv(.c) c_int {
    _ = @as([*][*:0]u8, @ptrCast(c_argv))[0..@as(usize, @intCast(c_argc))];
    @call(.always_inline, main, .{});
    return 0;
}

comptime {
    @export(&mainWithoutEnv, .{ .name = "__main_argc_argv" });
}
