import { WebSocketServer } from "ws";
import { GameManager } from "./gameManager.js";

const PORT = process.env.PORT || 8080;

const wss = new WebSocketServer({ port: PORT });
const gameManager = new GameManager();

wss.on("connection", function connection(ws) {
  gameManager.addPlayer(ws);
  ws.on("close", () => {
    gameManager.removePlayer(ws);
  });
});

console.log(`WebSocket server running on port ${PORT}`);
