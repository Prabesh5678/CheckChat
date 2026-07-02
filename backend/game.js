import { Chess } from "chess.js";

export class Game {
  constructor(player1, player2) {
    this.player1 = player1;
    this.player2 = player2;
    this.board = new Chess();
    this.moves = [];
    this.startTime = new Date();
    this.ended = false;
    this.player1.send(JSON.stringify({ type: "game_start", color: "white" }));
    this.player2.send(JSON.stringify({ type: "game_start", color: "black" }));
    this.voiceAvailable = false;
    this.videoAvailable = false;
  }

  notifyOpponentLeft(disconnectedSocket) {
    if (this.ended) return;
    this.ended = true;
    const opponent =
      disconnectedSocket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(JSON.stringify({ type: "opponent_disconnected" }));
    } catch {
      /* opponent already gone */
    }
  }

  sendChat(socket, message) {
    if (this.ended) return;
    if (!message || message.trim() === "" || message.length > 200) return;

    const from = socket === this.player1 ? "white" : "black";
    const payload = JSON.stringify({
      type: "chat",
      from,
      message: message.trim(),
    });

    this.player1.send(payload);
    this.player2.send(payload);
  }

  makeMove(socket, move) {
    if (this.ended) return;

    if (this.board.turn() === "w" && socket !== this.player1) return;
    if (this.board.turn() === "b" && socket !== this.player2) return;

    try {
      this.board.move(move);
    } catch {
      return;
    }

    this.player1.send(JSON.stringify({ type: "move_made", move }));
    this.player2.send(JSON.stringify({ type: "move_made", move }));

    if (this.board.isGameOver()) {
      this.ended = true;
      let result;

      if (this.board.isCheckmate()) {
        const winner = this.board.turn() === "w" ? "black" : "white";
        result = { winner, reason: "checkmate" };
      } else if (this.board.isStalemate()) {
        result = { winner: "draw", reason: "stalemate" };
      } else if (this.board.isInsufficientMaterial()) {
        result = { winner: "draw", reason: "insufficient_material" };
      } else if (this.board.isThreefoldRepetition()) {
        result = { winner: "draw", reason: "threefold_repetition" };
      } else if (this.board.isDraw()) {
        result = { winner: "draw", reason: "50_move_rule" };
      } else {
        result = { winner: "draw", reason: "unknown" };
      }

      this.player1.send(JSON.stringify({ type: "game_over", result }));
      this.player2.send(JSON.stringify({ type: "game_over", result }));
    }
  }

  handleVoiceRequest(socket) {
    if (this.ended) return;

    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(JSON.stringify({ type: "voice_request" }));
    } catch {
      /* opponent already gone */
    }
  }
   
  handleVoiceResponse(socket, data) {
    if (this.ended) return;
    if (!data || !data.accepted) return;
    this.voiceAvailable = data.accepted;
  }

  handleVideoRequest(socket) {
    if (this.ended) return; 
    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(JSON.stringify({ type: "video_request" }));
    } catch {
      /* opponent already gone */
    }
  }
  
  handleVideoResponse(socket, data) {
    if (this.ended) return;
    if (!data || !data.accepted) return;    
    this.videoAvailable = data.accepted;
  }

}
