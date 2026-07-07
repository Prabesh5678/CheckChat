import json
import logging

from .game import Game

logger = logging.getLogger(__name__)


class GameManager:
    """Singleton, mirrors the original Node GameManager. Matchmaking state
    lives in memory for a single ASGI worker process — the same assumption
    the original single-process `ws` server made. If you scale to multiple
    workers/replicas, this needs to move to a shared store (e.g. the channel
    layer + Redis) instead of plain Python objects.
    """

    def __init__(self):
        self.games = []
        self.pending_user = None
        self.users = []

    def add_player(self, socket):
        self.users.append(socket)

    def find_game(self, socket):
        for game in self.games:
            if game.player1 is socket or game.player2 is socket:
                return game
        return None

    async def remove_player(self, socket):
        self.users = [u for u in self.users if u is not socket]
        if self.pending_user is socket:
            self.pending_user = None

        game = self.find_game(socket)
        if game is not None:
            await game.notify_opponent_left(socket)
            self.games = [g for g in self.games if g is not game]

    async def handle_message(self, socket, raw_data):
        try:
            message = json.loads(raw_data)
        except Exception:
            return

        msg_type = message.get("type")

        if msg_type in ("rtc_offer", "rtc_answer", "rtc_ice"):
            logger.info(
                "[RTC][GameManager] incoming %s hasSdp=%s hasCandidate=%s",
                msg_type,
                bool(message.get("sdp")),
                bool(message.get("candidate")),
            )

        if msg_type == "init_game":
            existing = self.find_game(socket)
            if existing is not None:
                self.games = [g for g in self.games if g is not existing]

            if self.pending_user is not None and self.pending_user is not socket:
                game = Game(self.pending_user, socket)
                self.games.append(game)
                self.pending_user = None
                await game.start()
            else:
                self.pending_user = socket
            return

        if msg_type == "move":
            game = self.find_game(socket)
            if game:
                await game.make_move(socket, message.get("move"))
            return

        if msg_type == "chat":
            game = self.find_game(socket)
            if game:
                await game.send_chat(socket, message.get("message"))
            return

        if msg_type == "voice_request":
            game = self.find_game(socket)
            if game:
                await game.handle_voice_request(socket)
            return

        if msg_type == "voice_response":
            game = self.find_game(socket)
            if game:
                await game.handle_voice_response(socket, message)
            return

        if msg_type == "video_request":
            game = self.find_game(socket)
            if game:
                await game.handle_video_request(socket)
            return

        if msg_type == "video_response":
            game = self.find_game(socket)
            if game:
                await game.handle_video_response(socket, message)
            return

        if msg_type == "rtc_offer":
            game = self.find_game(socket)
            if not game:
                logger.info("[RTC][GameManager] no game found for rtc_offer")
                return
            await game.handle_rtc_offer(socket, message)
            return

        if msg_type == "rtc_answer":
            game = self.find_game(socket)
            if not game:
                logger.info("[RTC][GameManager] no game found for rtc_answer")
                return
            await game.handle_rtc_answer(socket, message)
            return

        if msg_type == "mic_toggle":
            logger.info("Received mic toggle message")
            game = self.find_game(socket)
            if not game:
                logger.info("Game not found for mic toggle")
                return
            await game.handle_mic_toggle(socket, message)
            return

        if msg_type == "camera_toggle":
            logger.info("Received camera toggle message")
            game = self.find_game(socket)
            if not game:
                logger.info("Game not found for camera toggle")
                return
            await game.handle_camera_toggle(socket, message)
            return

        if msg_type == "rtc_ice":
            game = self.find_game(socket)
            if not game:
                logger.info("[RTC][GameManager] no game found for rtc_ice")
                return
            await game.handle_rtc_ice(socket, message)
            return

        if msg_type == "resign":
            game = self.find_game(socket)
            if game:
                await game.handle_resign(socket)
            return

        if msg_type == "cancel_wait":
            if self.pending_user is socket:
                self.pending_user = None
            return


# Module-level singleton, same lifetime assumption as the original
# single-process Node server's `new GameManager()`.
game_manager = GameManager()
