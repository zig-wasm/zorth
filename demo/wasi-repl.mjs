// Main-thread bootstrap for demo/index.html: mounts xterm.js, feeds
// jonesforth.f to a Worker (see wasi-worker.js) over a uwasi
// SharedInputChannel, and uses xterm-readline for line editing. No real
// pty, unlike the xterm-pty-based demo this replaces -- wasi-worker.js's
// blocking fd_read plays the same role a pty's line discipline did.
import { Terminal } from "https://esm.sh/@xterm/xterm@5.5.0";
import { Readline } from "https://esm.sh/xterm-readline@1.1.2";
import { SharedInputChannel } from "https://esm.sh/uwasi@1.6.0";

/** @returns {Terminal} */
export function startRepl() {
    const xterm = new Terminal();
    const rl = new Readline();
    xterm.loadAddon(rl);
    xterm.open(document.getElementById("terminal"));

    // Sized well past jonesforth.f (~20 KiB).
    const channel = new SharedInputChannel(128 * 1024);
    const worker = new Worker(new URL("./wasi-worker.js", import.meta.url), { type: "module" });

    // Re-arms by calling itself from its own `rl.read().then()` so exactly
    // one read is ever pending: a submitted line that produces no output
    // (e.g. a blank line) must still arm the next read, which a purely
    // output-reactive re-arm would miss.
    function readLine() {
        rl.read("").then((text) => {
            channel.push(new TextEncoder().encode(text + "\n"));
            readLine();
        });
    }

    worker.addEventListener("message", async ({ data: { type, fd, data, code, message } }) => {
        switch (type) {
            case "ready": {
                const response = await fetch(new URL("./jonesforth.f", import.meta.url));
                channel.push(new Uint8Array(await response.arrayBuffer()));
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

    worker.postMessage({ sharedBuffer: channel.sharedBuffer });

    return xterm;
}
