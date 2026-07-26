const fs = require("fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (config.networks.httpServers[0].port !== 3005) throw new Error("HTTP port mismatch");
if (config.networks.wsClients[0].url !== "ws://127.0.0.1:6199/ws") throw new Error("WS URL mismatch");
if (config.networks.httpServers[0].accessToken !== "test-secret") throw new Error("HTTP token mismatch");
if (config.networks.wsClients[0].accessToken !== "test-secret") throw new Error("WS token mismatch");
console.log("OneBot config checks passed.");
