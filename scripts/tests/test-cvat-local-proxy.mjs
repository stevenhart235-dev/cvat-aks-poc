import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import test from "node:test";
import { createCvatLocalProxy, targetsBackend } from "../cvat-local-proxy.mjs";

function listen(server) {
    return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => resolve(server.address().port));
    });
}

function close(server) {
    return new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

function request(port, path, { method = "GET", body, headers = {} } = {}) {
    return new Promise((resolve, reject) => {
        const outgoing = http.request({ host: "127.0.0.1", port, path, method, headers }, (response) => {
            const chunks = [];
            response.on("data", (chunk) => chunks.push(chunk));
            response.on("end", () => resolve({
                status: response.statusCode,
                headers: response.headers,
                body: Buffer.concat(chunks).toString("utf8"),
            }));
        });
        outgoing.on("error", reject);
        if (body) outgoing.write(body);
        outgoing.end();
    });
}

function websocketRoundTrip(port) {
    return new Promise((resolve, reject) => {
        const socket = net.connect(port, "127.0.0.1");
        let received = "";
        socket.setTimeout(5000, () => socket.destroy(new Error("WebSocket proxy test timed out")));
        socket.on("connect", () => socket.write(
            "GET /api/events?org=demo HTTP/1.1\r\n" +
            `Host: 127.0.0.1:${port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n`,
        ));
        socket.on("data", (chunk) => {
            received += chunk.toString("utf8");
            if (received.includes("UPGRADED")) {
                socket.end();
                resolve(received);
            }
        });
        socket.on("error", reject);
    });
}

test("routes CVAT local traffic without changing HTTP or upgrade semantics", async () => {
    const seen = [];
    const frontend = http.createServer((req, res) => {
        seen.push({ upstream: "frontend", method: req.method, url: req.url });
        res.writeHead(200, { "content-type": "text/html", "x-upstream": "frontend" });
        res.end("UI");
    });
    const backend = http.createServer((req, res) => {
        const chunks = [];
        req.on("data", (chunk) => chunks.push(chunk));
        req.on("end", () => {
            seen.push({ upstream: "backend", method: req.method, url: req.url, body: Buffer.concat(chunks).toString() });
            res.writeHead(201, { "content-type": "application/json", "x-upstream": "backend" });
            res.end('{"ok":true}');
        });
    });
    backend.on("upgrade", (req, socket) => {
        seen.push({ upstream: "backend-upgrade", method: req.method, url: req.url });
        socket.end("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nUPGRADED");
    });

    const frontendPort = await listen(frontend);
    const backendPort = await listen(backend);
    const proxy = createCvatLocalProxy({ frontendPort, backendPort });
    const proxyPort = await listen(proxy);
    try {
        assert.equal(targetsBackend("/api/schema/?scheme=json&org="), true);
        assert.equal(targetsBackend("/apiary"), false);
        assert.equal(targetsBackend("/assets/app.js"), false);

        const ui = await request(proxyPort, "/login?next=%2Ftasks");
        assert.deepEqual([ui.status, ui.headers["content-type"], ui.headers["x-upstream"], ui.body], [200, "text/html", "frontend", "UI"]);

        const api = await request(proxyPort, "/api/tasks?org=demo", {
            method: "POST",
            body: '{"name":"test"}',
            headers: { "content-type": "application/json", "x-test-header": "preserved" },
        });
        assert.deepEqual([api.status, api.headers["content-type"], api.headers["x-upstream"], api.body], [201, "application/json", "backend", '{"ok":true}']);
        assert.deepEqual(seen.slice(0, 2), [
            { upstream: "frontend", method: "GET", url: "/login?next=%2Ftasks" },
            { upstream: "backend", method: "POST", url: "/api/tasks?org=demo", body: '{"name":"test"}' },
        ]);

        const upgraded = await websocketRoundTrip(proxyPort);
        assert.match(upgraded, /^HTTP\/1\.1 101 Switching Protocols/);
        assert.deepEqual(seen[2], { upstream: "backend-upgrade", method: "GET", url: "/api/events?org=demo" });

        await close(backend);
        const unavailable = await request(proxyPort, "/api/server/health/");
        assert.equal(unavailable.status, 502);
        assert.equal(unavailable.headers["content-type"], "application/json; charset=utf-8");
        assert.deepEqual(JSON.parse(unavailable.body), { error: "CVAT local proxy upstream unavailable" });
    } finally {
        await Promise.allSettled([close(proxy), close(frontend), close(backend)]);
    }
});
