// Worker-side half of running zorth.wasm's classic (blocking `read()`) WASI
// command in the browser. A program written assuming it owns stdin/stdout
// gets them wired to a `uwasi.SharedInputChannel`, so `fd_read` genuinely
// blocks (via `Atomics.wait`) until the host thread supplies more input,
// instead of returning EOF whenever nothing happens to be buffered yet.
//
// Must run on a thread that allows blocking `Atomics.wait` -- a Worker,
// never a browser main thread (see worker.js, which calls runWasiCommand()
// below; the host side, SharedInputChannel.push, is wired up by
// wasi-repl.mjs on the main thread instead).
import { WASI, useArgs, useClock, useEnviron, useProc, useRandom, useStdio, SharedInputChannel } from 'https://esm.sh/uwasi@1.6.0';

// uwasi's useStdio doesn't implement fd_pread/fd_pwrite. Zig's std.fs.File
// reader/writer (src/zorth.zig's main()) try positioned I/O before falling
// back to fd_read/fd_write; the default ENOSYS trips a panic ("unexpected
// errno: 52") instead of that fallback. Answering ESPIPE (WASI errno 70)
// for stdio's character-device fds makes the fallback happen, the same as
// a real OS would for an unseekable fd.
const ESPIPE = 70;
const ENOSYS = 52;
function noSeek() {
    return () => ({
        fd_pread: (fd) => (fd <= 2 ? ESPIPE : ENOSYS),
        fd_pwrite: (fd) => (fd <= 2 ? ESPIPE : ENOSYS),
    });
}

// uwasi's useStdio's fd_read (via ReadableTextProxy.readv) tries to
// completely fill the requested buffer, retrying `stdin()` until it can or
// hits true EOF. That's wrong for a classic POSIX read(): it's fine to
// return less than asked for, and zorth relies on exactly that --
// jonesforth's TIB refill always requests a fixed 4096 bytes regardless of
// how much input is actually left. jonesforth.f is essentially never an
// exact multiple of that, so the final, naturally short read makes readv()
// retry forever on a channel that's meant to stay open for more
// interactive input -- a hang, not a crash. Hand-roll fd_read instead,
// short reads and all; useStdio still covers fd_write/fd_fdstat_get/etc.,
// which never have this problem (writev() just writes whatever it's
// given, no retry loop).
function blockingRead(channel) {
    // ponytail: a 0ms Atomics.wait that can never actually wait (nothing else
    // ever touches index 0 of this buffer). Its only job is the documented
    // engine side effect of Atomics.wait pumping the agent cluster's pending
    // cross-thread messages. Without it, a guest that never genuinely blocks
    // (every fd_read is satisfied from input pushed up front, like
    // jonesforth.f's preamble) runs `_start` to completion in one
    // uninterrupted JS turn, and every `onOutput` postMessage queues up
    // behind it instead of reaching the main thread as it's produced -- so a
    // real browser never repaints until the run is already over. Confirmed
    // needed in Chromium; harmless in Node.
    const yieldBuffer = new Int32Array(new SharedArrayBuffer(4));
    return (options, abi, memoryView) => ({
        fd_read: (fd, iovs, iovsLen, nreadPtr) => {
            if (fd !== 0) return 8; // WASI_ERRNO_BADF
            const view = memoryView();
            // Bound consume() to what these iovecs can actually hold: it
            // otherwise happily returns everything buffered, up to the
            // channel's full capacity, and whatever doesn't fit in this
            // call's iovecs would be silently lost (consumed from the
            // channel, written nowhere).
            let capacity = 0;
            for (let i = 0; i < iovsLen; i++) {
                capacity += view.getUint32(iovs + i * 8 + 4, true);
            }
            // A zero-length request is a valid read() that's always
            // satisfiable with zero bytes: don't block waiting for input
            // nobody asked for.
            if (capacity === 0) {
                view.setUint32(nreadPtr, 0, true);
                return 0; // WASI_ESUCCESS
            }
            channel.waitForInput(null);
            Atomics.wait(yieldBuffer, 0, 0, 0);
            const bytes = channel.consume(capacity);
            let totalRead = 0;
            for (let i = 0; i < iovsLen && totalRead < bytes.length; i++) {
                const iovecPtr = iovs + i * 8;
                const bufPtr = view.getUint32(iovecPtr, true);
                const bufLen = view.getUint32(iovecPtr + 4, true);
                const n = Math.min(bufLen, bytes.length - totalRead);
                new Uint8Array(view.buffer, bufPtr, n).set(bytes.subarray(totalRead, totalRead + n));
                totalRead += n;
            }
            view.setUint32(nreadPtr, totalRead, true);
            return 0; // WASI_ESUCCESS
        },
    });
}

/**
 * @param {BufferSource | WebAssembly.Module} wasm compiled WASI command (`_start`)
 * @param {SharedArrayBuffer} sharedBuffer a host-created `SharedInputChannel`'s buffer
 * @param {(fd: 1 | 2, chunk: string) => void} onOutput stdout (1) / stderr (2), already UTF-8 decoded
 * @returns {Promise<number>} the WASI exit code
 */
export async function runWasiCommand(wasm, sharedBuffer, onOutput) {
    const channel = new SharedInputChannel(sharedBuffer);
    const wasi = new WASI({
        features: [
            // A libc/language-runtime startup sequence can probe these
            // before ever touching stdin -- missing ones resolve to ENOSYS,
            // which zorth would otherwise turn into an early, silent exit.
            useArgs(),
            useClock(),
            useEnviron(),
            useRandom(),
            useProc(),
            noSeek(),
            useStdio({
                stdout: (chunk) => onOutput(1, chunk),
                stderr: (chunk) => onOutput(2, chunk),
            }),
            // After useStdio, so this fd_read overrides its fill-the-buffer one.
            blockingRead(channel),
        ],
    });

    // `instantiate(bytes, ...)` resolves to `{ module, instance }`;
    // `instantiate(module, ...)` resolves to the instance directly.
    const result = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: wasi.wasiImport });
    const instance = result instanceof WebAssembly.Instance ? result : result.instance;
    return wasi.start(instance);
}
