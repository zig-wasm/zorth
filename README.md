# zorth
## Forth in Zig and WebAssembly

[Forth](https://en.wikipedia.org/wiki/Forth_(programming_language)) is a 
prehistoric [esolang](https://en.wikipedia.org/wiki/Esoteric_programming_language).
It has little to no syntax and blurs the boundary between interpreted and
compiled.  Its implementations often rely on either 
[indirect branches](https://en.wikipedia.org/wiki/Indirect_branch) or
[tail calls](https://en.wikipedia.org/wiki/Tail_call).  Structured programming
languages use [labels as values](https://gcc.gnu.org/onlinedocs/gcc/Labels-as-Values.html)
to represent indirect branches and we all know these are
[considered harmful](https://en.wikipedia.org/wiki/Considered_harmful) so let us
explore tail calls instead.

As luck would have it, [Zig](https://ziglang.org) specifies `.always_tail` in the
language itself.  That makes it an ideal modern implementation target.

## ✨ Try it in your browser ✨

➡️ **https://zigwasm.org/zorth**
