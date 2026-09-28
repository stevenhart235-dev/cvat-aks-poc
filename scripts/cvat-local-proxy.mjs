import http from "node:http";
import { pathToFileURL } from "node:url";

const backendPrefixes = ["/api", "/admin", "/static", "/django-rq", "/profiler"];

export function targetsBackend(requestTarget) {
    const pathname = new URL(requestTarget, "http://127.0.0.1").pathname;
    return backendPrefixes.some((prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`));
}

function sendProxyError(response, error) {
    if (response.headersSent) {
        response.destroy(error);
        return;
    }
    const body = JSON.stringify({ error: "CVAT local proxy upstream unavailable" });
    response.writeHead(502, {
        "content-type": "application/json; charset=utf-8",
        "content-length": Buffer.byteLength(body),
    });
    response.end(body);
}

function sendUpgradeError(socket) {
    if (!socket.destroyed) {
        const body = "CVAT local proxy upstream unavailable\n";
        socket.end(
            `HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\n` +
            `Content-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
        );
    }
}

function writeUpgradeResponse(socket, response) {
    socket.write(`HTTP/${response.httpVersion} ${response.statusCode} ${response.statusMessage}\r\n`);
    for (let index = 0; index < response.rawHeaders.length; index += 2) {
        socket.write(`${response.rawHeaders[index]}: ${response.rawHeaders[index + 1]}\r\n`);
    }
    socket.write("\r\n");
}

export function createCvatLocalProxy({
    upstreamHost = "127.0.0.1",
    frontendPort = 18000,
    backendPort = 18080,
} = {}) {
    const server = http.createServer((request, response) => {
        const port = targetsBackend(request.url) ? backendPort : frontendPort;
        const upstream = http.request({
            host: upstreamHost,
            port,
            method: request.method,
            path: request.url,
            headers: request.headers,
        }, (upstreamResponse) => {
            response.writeHead(upstreamResponse.statusCode ?? 502, upstreamResponse.headers);
            upstreamResponse.pipe(response);
        });

        upstream.on("error", (error) => sendProxyError(response, error));
        request.on("aborted", () => upstream.destroy());
        request.pipe(upstream);
    });

    server.on("upgrade", (request, socket, head) => {
        const port = targetsBackend(request.url) ? backendPort : frontendPort;
        const upstream = http.request({
            host: upstreamHost,
            port,
            method: request.method,
            path: request.url,
            headers: request.headers,
        });

        upstream.on("upgrade", (upstreamResponse, upstreamSocket, upstreamHead) => {
            writeUpgradeResponse(socket, upstreamResponse);
            if (upstreamHead.length) socket.write(upstreamHead);
            if (head.length) upstreamSocket.write(head);
            upstreamSocket.on("error", () => socket.destroy());
            socket.on("error", () => upstreamSocket.destroy());
            upstreamSocket.pipe(socket);
            socket.pipe(upstreamSocket);
        });
        upstream.on("response", (upstreamResponse) => {
            writeUpgradeResponse(socket, upstreamResponse);
            upstreamResponse.pipe(socket);
        });
        upstream.on("error", () => sendUpgradeError(socket));
        upstream.end();
    });

    server.on("clientError", (_error, socket) => {
        if (!socket.destroyed) socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    });
    return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const server = createCvatLocalProxy();
    server.listen(8081, "127.0.0.1", () => {
        console.log("CVAT local proxy listening at http://127.0.0.1:8081/");
        console.log("Frontend upstream: http://127.0.0.1:18000; backend upstream: http://127.0.0.1:18080");
    });
    server.on("error", (error) => {
        console.error(`CVAT local proxy failed: ${error.message}`);
        process.exitCode = 1;
    });
}
