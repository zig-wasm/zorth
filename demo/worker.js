// Web Worker that fetches zorth.wasm and drives it through the shared
// `runWasiCommand` (see wasi-worker.js), which blocks stdin on a
// `uwasi.SharedInputChannel` that the main thread (wasi-repl.mjs) feeds
// from the terminal.
import { runWasiCommand } from './wasi-worker.js';

self.addEventListener('message', async ({ data: { sharedBuffer, wasmUrl = './zorth.wasm' } }) => {
    try {
        const bytes = await fetch(wasmUrl).then((response) => response.arrayBuffer());
        self.postMessage({ type: 'ready' });
        const code = await runWasiCommand(bytes, sharedBuffer, (fd, chunk) => {
            self.postMessage({ type: 'output', fd, data: chunk });
        });
        self.postMessage({ type: 'exit', code });
    } catch (error) {
        self.postMessage({ type: 'error', message: error.message, stack: error.stack });
    }
});
