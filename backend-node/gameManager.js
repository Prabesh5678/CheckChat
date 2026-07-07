import { Game } from "./game.js";

export class GameManager {
  constructor() {
    this.games = [];
    this.pendingUser = null;
    this.users = [];
  }

  addPlayer(socket) {
    this.users.push(socket);
    this.addHandler(socket);
  }

  removePlayer(socket) {
    this.users = this.users.filter((user) => user !== socket);

    if (this.pendingUser === socket) {
      this.pendingUser = null;
    }

    const gameIndex = this.games.findIndex(
      (game) => game.player1 === socket || game.player2 === socket,
    );
    if (gameIndex !== -1) {
      this.games[gameIndex].notifyOpponentLeft(socket);
      this.games.splice(gameIndex, 1);
    }
  }

  addHandler(socket) {
    socket.on("message", (data) => {
      let message;
      try {
        message = JSON.parse(data.toString());
      } catch {
        return;
      }

      if (
        message.type === "rtc_offer" ||
        message.type === "rtc_answer" ||
        message.type === "rtc_ice"
      ) {
        console.log("[RTC][GameManager] incoming", message.type, {
          hasSdp: !!message.sdp,
          hasCandidate: !!message.candidate,
        });
      }

      if (message.type === "init_game") {
        const existingIndex = this.games.findIndex(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (existingIndex !== -1) {
          this.games.splice(existingIndex, 1);
        }

        if (this.pendingUser && this.pendingUser !== socket) {
          const game = new Game(this.pendingUser, socket);
          this.games.push(game);
          this.pendingUser = null;
        } else {
          this.pendingUser = socket;
        }
      }

      if (message.type === "move") {
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) return;
        game.makeMove(socket, message.move);
      }

      if (message.type === "chat") {
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) return;
        game.sendChat(socket, message.message);
      }

      if (message.type === "voice_request") {
        //done
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) return;
        game.handleVoiceRequest(socket);
      }
      if (message.type === "voice_response") {
        //done
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) return;
        game.handleVoiceResponse(socket, message);
      }
      if (message.type === "video_request") {
        //done
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) return;
        game.handleVideoRequest(socket);
      }
      if (message.type === "video_response") {
        //done
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) return;
        game.handleVideoResponse(socket, message);
      }
      if (message.type === "rtc_offer") {
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) {
          console.log("[RTC][GameManager] no game found for rtc_offer");
          return;
        }
        game.handleRTCOffer(socket, message);
      }
      if (message.type === "rtc_answer") {
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) {
          console.log("[RTC][GameManager] no game found for rtc_answer");
          return;
        }
        game.handleRTCAnswer(socket, message);
      }
      if (message.type === "mic_toggle") {
        console.log('Received mic toggle message');
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) {console.log("Game not found for mic toggle"); return};
        game.handleMicToggle(socket, message);
      }
      if (message.type === "camera_toggle") {
        console.log('Received camera toggle message');
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) {console.log("Game not found for camera toggle"); return};
        game.handleCameraToggle(socket, message);
      }
      if (message.type === "rtc_ice") {
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) {
          console.log("[RTC][GameManager] no game found for rtc_ice");
          return;
        }
        game.handleRtcIce(socket, message);
      }
      if (message.type === "resign") {
        const game = this.games.find(
          (game) => game.player1 === socket || game.player2 === socket,
        );
        if (!game) return;
        game.handleResign(socket);
      }

      if (message.type === "cancel_wait") {
        if (this.pendingUser === socket) {
          this.pendingUser = null;
        }
      }
    });
  }
}
