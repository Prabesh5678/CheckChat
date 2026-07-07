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
    this.rtc = {
      pendingVoiceRequest: false,
      pendingVideoRequest: false,
      voiceAvailable: false,
      videoAvailable: false,
      player1Voice: false,
      player2Voice: false,
      player1Video: false,
      player2Video: false,
    };
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
    this.rtc.pendingVoiceRequest = true;
    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(JSON.stringify({ type: "voice_request" }));
      console.log("Voice request sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
      return;
    }
  }

  handleVoiceResponse(socket, data) {
    if (this.ended || this.rtc.pendingVoiceRequest === false) return;
    console.log("Voice response received:", data);
    if (!data) {
      console.error("Invalid voice response data");
      return;
    }

    this.rtc.voiceAvailable = data.accepted;
    try {
      const opponent = socket === this.player1 ? this.player2 : this.player1;
      opponent.send(
        JSON.stringify({ type: "voice_response", accepted: data.accepted }),
      );
      console.log("Voice response sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
      console.log("Failed to send voice response to opponent");
      return;
    }
  }

  handleVideoRequest(socket) {
    if (this.ended) return;
    this.rtc.pendingVideoRequest = true;
    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(JSON.stringify({ type: "video_request" }));
      console.log("Video request sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
      console.log("Failed to send video request to opponent");
      return;
    }
  }

  handleVideoResponse(socket, data) {
    if (this.ended || this.rtc.pendingVideoRequest === false) {
      console.log(
        "Video response received but game ended or no pending request",
      );
      return;
    }
    console.log("Video response received:", data);
    // Expect `{ accepted: true|false }` — accept both answers and declines.
    if (!data) {
      console.error("Invalid video response data");
      // Clear pending flag to avoid leaving the game in a waiting state.
      this.rtc.pendingVideoRequest = false;
      return;
    }

    // Update rtc state and clear pending flag.
    this.rtc.videoAvailable = data.accepted;
    this.rtc.pendingVideoRequest = false;

    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(
        JSON.stringify({ type: "video_response", accepted: data.accepted }),
      );
      console.log("Video response sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
    }
  }

  handleRTCOffer(socket, message) {
    if (this.ended) return;
    if (!this.rtc.voiceAvailable && !this.rtc.videoAvailable) return;
    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(JSON.stringify({ type: "rtc_offer", sdp: message.sdp }));
      console.log("RTC offer sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
      return;
    }
  }

  handleRTCAnswer(socket, message) {
    if (this.ended) return;
    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(JSON.stringify({ type: "rtc_answer", sdp: message.sdp }));
      console.log("RTC answer sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
      return;
    }
  }

  handleRtcIce(socket, message) {
    if (this.ended) return;
    if (!this.rtc.voiceAvailable && !this.rtc.videoAvailable) return;
    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(
        JSON.stringify({ type: "rtc_ice", candidate: message.candidate }),
      );
      console.log("RTC ice sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
      return;
    }
  }

  handleMicToggle(socket, data) {
    if (this.ended) return;
    const opponent = socket === this.player1 ? this.player2 : this.player1;
    try {
      opponent.send(
        JSON.stringify({ type: "mic_toggle", enabled: data.enabled }),
      );
      console.log("Mic toggle sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
      return;
    }
    if (this.rtc.voiceAvailable) {
      if (socket === this.player1) {
        this.rtc.player1Voice = data.enabled;
      } else if (socket === this.player2) {
        this.rtc.player2Voice = data.enabled;
      }
    }
  }

  handleCameraToggle(socket, data) {
    if (this.ended) {
      console.log("Game has ended.");
      return;
    }
    const opponent = socket === this.player1 ? this.player2 : this.player1;
    console.log("Camera toggle data:", data);
    try {
      opponent.send(
        JSON.stringify({ type: "camera_toggle", enabled: data.enabled }),
      );
      console.log("Camera toggle sent to opponent");
    } catch {
      console.error("opponent socket is closed or not available");
      return;
    }
    console.log("videoAvailable:", this.rtc.videoAvailable);
    if (this.rtc.videoAvailable) {
      if (socket === this.player1) {
        this.rtc.player1Video = data.enabled;
      } else if (socket === this.player2) {
        this.rtc.player2Video = data.enabled;
      }
    }
  }
  handleResign(socket) {
    if (this.ended) return;
    this.ended = true;
    const winner = socket === this.player1 ? "black" : "white";
    this.player1.send(
      JSON.stringify({
        type: "game_over",
        result: { winner, reason: "resign" },
      }),
    );
    this.player2.send(
      JSON.stringify({
        type: "game_over",
        result: { winner, reason: "resign" },
      }),
    );
  }
}
