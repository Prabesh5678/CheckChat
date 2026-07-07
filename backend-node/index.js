import http from "http";
import express from "express";
import cors from "cors";
import { WebSocketServer } from "ws";
import { GameManager } from "./gameManager.js";
import paymentsRouter from "./routes/payment.route.js";
import dotenv from "dotenv";
dotenv.config();

const PORT = process.env.PORT || 8080;

const app = express();
app.use(cors());
app.use(express.json());
app.use((req,_, next) => {
  console.log(`[http] ${req.method} ${req.url}`);
  next();
});

app.use("/api/payments", paymentsRouter);

app.get("/health", (_req, res) => res.json({ ok: true }));

const server = http.createServer(app);

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.error(
      `[server] FATAL: port ${PORT} is already in use by another process. ` +
        `Find and stop it, or run this server on a different port ` +
        `(PORT=8081 node server.js).`,
    );
  } else if (err.code === "EACCES") {
    console.error(
      `[server] FATAL: no permission to bind port ${PORT} ` +
        `(ports below 1024 usually need admin/root — try a port above 1024).`,
    );
  } else {
    console.error("[server] FATAL: failed to start:", err);
  }
  process.exit(1);
});

const wss = new WebSocketServer({ server });
const gameManager = new GameManager();

// ping every 60 seconds to detect dead connections
const interval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) {
      gameManager.removePlayer(ws);
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 60000);

wss.on("close", () => clearInterval(interval));

wss.on("connection", function connection(ws) {
  ws.isAlive = true;
  ws.on("pong", () => {
    ws.isAlive = true;
  }); // client responds to ping
  gameManager.addPlayer(ws);
  ws.on("close", () => {
    gameManager.removePlayer(ws);
  });
});

server.listen(PORT, () => {
  const addr = server.address();
  console.log(
    `HTTP + WebSocket server running on port ${PORT} ` +
      `(bound address: ${JSON.stringify(addr)})`,
  );
});
