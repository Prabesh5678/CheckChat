import json
import logging

import chess

logger = logging.getLogger(__name__)


def _parse_move(board, move):
    """Accept the same move shapes the frontend already sends to chess.js:
    a SAN string like "Nf3", or an object like {"from": "e2", "to": "e4", "promotion": "q"}.
    Pushes the move onto the board if legal. Returns True on success, False if
    illegal/unparseable (mirrors the try/catch around board.move() in game.js).
    """
    try:
        if isinstance(move, str):
            board.push_san(move)
            return True

        if isinstance(move, dict):
            uci = f"{move['from']}{move['to']}{move.get('promotion', '')}"
            chess_move = chess.Move.from_uci(uci)
            if chess_move not in board.legal_moves:
                return False
            board.push(chess_move)
            return True
    except Exception:
        return False
    return False


class Game:
    def __init__(self, player1, player2):
        self.player1 = player1  # consumer instances (analogous to the ws sockets)
        self.player2 = player2
        self.board = chess.Board()
        self.moves = []
        self.ended = False
        self.rtc = {
            "pendingVoiceRequest": False,
            "pendingVideoRequest": False,
            "voiceAvailable": False,
            "videoAvailable": False,
            "player1Voice": False,
            "player2Voice": False,
            "player1Video": False,
            "player2Video": False,
        }

    async def start(self):
        await self.player1.send(json.dumps({"type": "game_start", "color": "white"}))
        await self.player2.send(json.dumps({"type": "game_start", "color": "black"}))

    async def notify_opponent_left(self, disconnected_socket):
        if self.ended:
            return
        self.ended = True
        opponent = self.player2 if disconnected_socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "opponent_disconnected"}))
        except Exception:
            pass  # opponent already gone

    async def send_chat(self, socket, message):
        if self.ended:
            return
        if not message or not message.strip() or len(message) > 200:
            return

        frm = "white" if socket is self.player1 else "black"
        payload = json.dumps({"type": "chat", "from": frm, "message": message.strip()})
        await self.player1.send(payload)
        await self.player2.send(payload)

    async def make_move(self, socket, move):
        if self.ended:
            return

        turn_is_white = self.board.turn == chess.WHITE
        if turn_is_white and socket is not self.player1:
            return
        if not turn_is_white and socket is not self.player2:
            return

        if not _parse_move(self.board, move):
            return

        self.moves.append(move)
        payload = json.dumps({"type": "move_made", "move": move})
        await self.player1.send(payload)
        await self.player2.send(payload)

        if self.board.is_game_over():
            self.ended = True
            result = self._determine_result()
            over_payload = json.dumps({"type": "game_over", "result": result})
            await self.player1.send(over_payload)
            await self.player2.send(over_payload)

    def _determine_result(self):
        board = self.board
        if board.is_checkmate():
            winner = "black" if board.turn == chess.WHITE else "white"
            return {"winner": winner, "reason": "checkmate"}
        if board.is_stalemate():
            return {"winner": "draw", "reason": "stalemate"}
        if board.is_insufficient_material():
            return {"winner": "draw", "reason": "insufficient_material"}
        if board.can_claim_threefold_repetition():
            return {"winner": "draw", "reason": "threefold_repetition"}
        if board.can_claim_fifty_moves():
            return {"winner": "draw", "reason": "50_move_rule"}
        return {"winner": "draw", "reason": "unknown"}

    async def handle_voice_request(self, socket):
        if self.ended:
            return
        self.rtc["pendingVoiceRequest"] = True
        opponent = self.player2 if socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "voice_request"}))
            logger.info("Voice request sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")

    async def handle_voice_response(self, socket, data):
        if self.ended or not self.rtc["pendingVoiceRequest"]:
            return
        logger.info("Voice response received: %s", data)
        if not data:
            logger.error("Invalid voice response data")
            return

        self.rtc["voiceAvailable"] = data.get("accepted")
        opponent = self.player2 if socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "voice_response", "accepted": data.get("accepted")}))
            logger.info("Voice response sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")

    async def handle_video_request(self, socket):
        if self.ended:
            return
        self.rtc["pendingVideoRequest"] = True
        opponent = self.player2 if socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "video_request"}))
            logger.info("Video request sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")

    async def handle_video_response(self, socket, data):
        if self.ended or not self.rtc["pendingVideoRequest"]:
            logger.info("Video response received but game ended or no pending request")
            return
        logger.info("Video response received: %s", data)
        if not data:
            logger.error("Invalid video response data")
            self.rtc["pendingVideoRequest"] = False
            return

        self.rtc["videoAvailable"] = data.get("accepted")
        self.rtc["pendingVideoRequest"] = False

        opponent = self.player2 if socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "video_response", "accepted": data.get("accepted")}))
            logger.info("Video response sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")

    async def handle_rtc_offer(self, socket, message):
        if self.ended:
            return
        if not self.rtc["voiceAvailable"] and not self.rtc["videoAvailable"]:
            return
        opponent = self.player2 if socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "rtc_offer", "sdp": message.get("sdp")}))
            logger.info("RTC offer sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")

    async def handle_rtc_answer(self, socket, message):
        if self.ended:
            return
        opponent = self.player2 if socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "rtc_answer", "sdp": message.get("sdp")}))
            logger.info("RTC answer sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")

    async def handle_rtc_ice(self, socket, message):
        if self.ended:
            return
        if not self.rtc["voiceAvailable"] and not self.rtc["videoAvailable"]:
            return
        opponent = self.player2 if socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "rtc_ice", "candidate": message.get("candidate")}))
            logger.info("RTC ice sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")

    async def handle_mic_toggle(self, socket, data):
        if self.ended:
            return
        opponent = self.player2 if socket is self.player1 else self.player1
        try:
            await opponent.send(json.dumps({"type": "mic_toggle", "enabled": data.get("enabled")}))
            logger.info("Mic toggle sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")
            return
        if self.rtc["voiceAvailable"]:
            if socket is self.player1:
                self.rtc["player1Voice"] = data.get("enabled")
            elif socket is self.player2:
                self.rtc["player2Voice"] = data.get("enabled")

    async def handle_camera_toggle(self, socket, data):
        if self.ended:
            logger.info("Game has ended.")
            return
        opponent = self.player2 if socket is self.player1 else self.player1
        logger.info("Camera toggle data: %s", data)
        try:
            await opponent.send(json.dumps({"type": "camera_toggle", "enabled": data.get("enabled")}))
            logger.info("Camera toggle sent to opponent")
        except Exception:
            logger.error("opponent socket is closed or not available")
            return
        logger.info("videoAvailable: %s", self.rtc["videoAvailable"])
        if self.rtc["videoAvailable"]:
            if socket is self.player1:
                self.rtc["player1Video"] = data.get("enabled")
            elif socket is self.player2:
                self.rtc["player2Video"] = data.get("enabled")

    async def handle_resign(self, socket):
        if self.ended:
            return
        self.ended = True
        winner = "black" if socket is self.player1 else "white"
        payload = json.dumps({"type": "game_over", "result": {"winner": winner, "reason": "resign"}})
        await self.player1.send(payload)
        await self.player2.send(payload)
