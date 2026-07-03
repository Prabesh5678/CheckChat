import { WebSocketServer } from "ws";
import { GameManager } from "./gameManager.js";

const PORT = process.env.PORT || 8080;

const wss = new WebSocketServer({ port: PORT });
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

console.log(`WebSocket server running on port ${PORT}`);
