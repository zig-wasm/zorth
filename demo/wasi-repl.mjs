// Main-thread bootstrap for demo/index.html: mounts xterm.js, feeds
// jonesforth.f to a Worker (see worker.js) over a uwasi SharedInputChannel,
// and uses xterm-readline for line editing. No real pty, unlike the
// xterm-pty-based demo this replaces -- `wasi-worker.js`'s blocking fd_read
// plays the same role a pty's line discipline did.
import { Terminal } from "https://esm.sh/@xterm/xterm@5.5.0";
import { Readline } from "https://esm.sh/xterm-readline@1.1.2";
import { SharedInputChannel } from "https://esm.sh/uwasi@1.6.0";

/**
 * @param {string} wasmUrl
 * @param {string | URL} [preambleUrl] defaults to jonesforth.f, installed
 *   alongside this file by build.zig.
 * @param {string | HTMLElement} [container] defaults to `#terminal`.
 * @returns {{ term: Terminal, dispose: () => void }}
 */
export function startRepl(wasmUrl, preambleUrl = new URL("./jonesforth.f", import.meta.url), container = "terminal") {
    const xterm = new Terminal();
    const rl = new Readline();
    xterm.loadAddon(rl);
    xterm.open(typeof container === "string" ? document.getElementById(container) : container);

    // Sized well past jonesforth.f (~20 KiB).
    const channel = new SharedInputChannel(128 * 1024);
    const worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });

    let disposed = false;

    // Re-arms by calling itself from its own `rl.read().then()` so exactly
    // one read is ever pending: a submitted line that produces no output
    // (e.g. a blank line) must still arm the next read, which a purely
    // output-reactive re-arm would miss.
    function readLine() {
        if (disposed) return;
        rl.read("").then((text) => {
            channel.push(new TextEncoder().encode(text + "\n"));
            readLine();
        });
    }

    worker.addEventListener("message", async ({ data: { type, fd, data, code, message } }) => {
        // A disposed REPL's Worker is terminate()d below, but a message it
        // already posted before that lands here can still race the
        // termination (same microtask queue) -- never touch `rl`/`xterm`
        // past dispose(), both are themselves torn down by then.
        if (disposed) return;
        switch (type) {
            case "ready": {
                if (preambleUrl) {
                    const response = await fetch(preambleUrl);
                    channel.push(new Uint8Array(await response.arrayBuffer()));
                }
                readLine();
                break;
            }
            case "output":
                if (fd === 1 || fd === 2) rl.write(data);
                break;
            case "exit":
                rl.println(`[Process exited with code ${code}]`);
                break;
            case "error":
                rl.println(`[Error: ${message}]`);
                break;
        }
    });

    function dispose() {
        if (disposed) return;
        disposed = true;
        worker.terminate();
        xterm.dispose();
    }

    worker.postMessage({ sharedBuffer: channel.sharedBuffer, wasmUrl });

    return { term: xterm, dispose };
}
