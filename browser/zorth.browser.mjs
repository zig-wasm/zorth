import assert from "node:assert/strict";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, test } from "node:test";
import puppeteer from "puppeteer";

const root = resolve(fileURLToPath(new URL("../zig-out", import.meta.url)));
const expected = ": QUIT R0 RSP! INTERPRET BRANCH ( -8 ) ;";
const sharedHeaders = {
    "cross-origin-embedder-policy": "require-corp",
    "cross-origin-opener-policy": "same-origin",
};

function contentType(pathname) {
    return ({
        ".css": "text/css; charset=utf-8",
        ".f": "text/plain; charset=utf-8",
        ".html": "text/html; charset=utf-8",
        ".js": "text/javascript; charset=utf-8",
        ".mjs": "text/javascript; charset=utf-8",
        ".wasm": "application/wasm",
    })[extname(pathname)] ?? "application/octet-stream";
}

function filePath(pathname) {
    const relative = normalize(pathname).replace(/^\/+/, "");
    if (relative.startsWith("..")) return null;
    return join(root, relative || "index.html");
}

async function startServer() {
    const server = createServer(async (req, res) => {
        try {
            const url = new URL(req.url ?? "/", "http://127.0.0.1");
            const path = filePath(url.pathname);
            if (!path) {
                res.writeHead(404).end("not found");
                return;
            }
            const body = await readFile(path);
            res.writeHead(200, { ...sharedHeaders, "content-type": contentType(path) });
            res.end(body);
        } catch {
            res.writeHead(404, sharedHeaders).end("not found");
        }
    });
    server.listen(0, "localhost");
    await once(server, "listening");
    const { port } = server.address();
    return {
        origin: `http://localhost:${port}`,
        async close() {
            server.closeAllConnections();
            server.close();
            await once(server, "close");
        },
    };
}

function terminalText(page) {
    return page.evaluate(() => {
        const term = window.__xterm;
        if (!term) return "";
        const lines = [];
        const active = term.buffer.active;
        for (let i = 0; i < active.length; i += 1) {
            const line = active.getLine(i);
            if (line) lines.push(line.translateToString(true));
        }
        return lines.join("\n").replaceAll("\u00a0", " ").replaceAll("\r", "");
    });
}

function installTerminalHook(page) {
    return page.evaluateOnNewDocument(() => {
        Object.defineProperty(window, "Terminal", {
            configurable: true,
            set(value) {
                const Wrapped = function (...args) {
                    const term = new value(...args);
                    window.__xterm = term;
                    return term;
                };
                Object.setPrototypeOf(Wrapped, value);
                Wrapped.prototype = value.prototype;
                Object.defineProperty(window, "Terminal", {
                    value: Wrapped,
                    writable: true,
                    configurable: true,
                });
            },
        });
    });
}

function waitForTerminalText(page, needle) {
    return page.waitForFunction(
        (text) => {
            const term = window.__xterm;
            if (!term) return false;
            const active = term.buffer.active;
            const lines = [];
            for (let i = 0; i < active.length; i += 1) {
                const line = active.getLine(i);
                if (line) lines.push(line.translateToString(true));
            }
            return lines.join("\n").includes(text);
        },
        { timeout: 90_000 },
        needle,
    );
}

function diagnostics(page) {
    return page.evaluate(() => ({
        crossOriginIsolated,
        hasSharedArrayBuffer: typeof SharedArrayBuffer === "function",
        hasTerminal: !!window.__xterm,
        text: document.body.innerText,
    }));
}

let browser;
let server;

before(async () => {
    server = await startServer();
    browser = await puppeteer.launch({
        headless: true,
        args: process.platform === "linux"
            ? ["--no-sandbox", "--enable-features=SharedArrayBuffer"]
            : [],
    });
});

after(async () => {
    await browser?.close();
    await server?.close();
});

test("SEE QUIT decompiles QUIT in the browser demo", { timeout: 120_000 }, async () => {
    const page = await browser.newPage();
    await installTerminalHook(page);
    page.on("console", (message) => {
        if (message.type() === "warning" || message.type() === "error") {
            console.error(`[browser:${message.type()}] ${message.text()}`);
        }
    });
    page.on("pageerror", (error) => {
        console.error(`[browser:pageerror] ${error.stack ?? error.message}`);
    });
    await page.goto(server.origin, { waitUntil: "networkidle0" });
    await page.waitForFunction(
        () => document.querySelector("#terminal .xterm-screen, #terminal canvas") !== null,
    );
    try {
        await waitForTerminalText(page, "JONESFORTH VERSION");
    } catch (error) {
        assert.fail(`terminal never printed banner: ${JSON.stringify(await diagnostics(page))}\n${error}`);
    }

    await page.click("#terminal");
    await page.keyboard.type("SEE QUIT");
    await page.keyboard.press("Enter");

    try {
        await waitForTerminalText(page, expected);
    } catch (error) {
        assert.fail(`terminal never printed SEE QUIT output: ${JSON.stringify(await diagnostics(page))}\n${error}`);
    }

    const text = await terminalText(page);
    assert.match(text, new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    await page.close();
});
