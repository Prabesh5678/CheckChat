package com.chess.backend.chess;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.github.bhlangonijr.chesslib.Board;
import com.github.bhlangonijr.chesslib.Piece;
import com.github.bhlangonijr.chesslib.Side;
import com.github.bhlangonijr.chesslib.Square;
import com.github.bhlangonijr.chesslib.move.Move;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Port of game.js. Move parsing note: this accepts moves as either a
 * {from, to, promotion} JSON object, or a plain 4-5 character UCI string
 * ("e2e4", "e7e8q") — NOT full SAN ("Nf3"). If your frontend's chess.js
 * integration sends SAN strings, either switch it to send
 * {from, to, promotion} objects (the format the Django/Node versions relied
 * on primarily too), or add a SAN parser here using chesslib's move-generation
 * + comparison utilities.
 */
public class Game {

    private static final Logger log = LoggerFactory.getLogger(Game.class);

    private final ObjectMapper mapper = new ObjectMapper();

    private final WebSocketSession player1; // white
    private final WebSocketSession player2; // black
    private final Board board = new Board();
    private boolean ended = false;

    private boolean pendingVoiceRequest = false;
    private boolean pendingVideoRequest = false;
    private boolean voiceAvailable = false;
    private boolean videoAvailable = false;

    public Game(WebSocketSession player1, WebSocketSession player2) {
        this.player1 = player1;
        this.player2 = player2;
    }

    public WebSocketSession getPlayer1() { return player1; }
    public WebSocketSession getPlayer2() { return player2; }
    public boolean isEnded() { return ended; }

    public void start() {
        send(player1, Map.of("type", "game_start", "color", "white"));
        send(player2, Map.of("type", "game_start", "color", "black"));
    }

    public void notifyOpponentLeft(WebSocketSession disconnected) {
        if (ended) return;
        ended = true;
        WebSocketSession opponent = disconnected.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "opponent_disconnected"));
    }

    public void sendChat(WebSocketSession socket, String message) {
        if (ended) return;
        if (message == null || message.trim().isEmpty() || message.length() > 200) return;

        String from = socket.equals(player1) ? "white" : "black";
        Map<String, Object> payload = Map.of("type", "chat", "from", from, "message", message.trim());
        send(player1, payload);
        send(player2, payload);
    }

    public void makeMove(WebSocketSession socket, JsonNode moveNode) {
        if (ended) return;

        boolean whiteToMove = board.getSideToMove() == Side.WHITE;
        if (whiteToMove && !socket.equals(player1)) return;
        if (!whiteToMove && !socket.equals(player2)) return;

        if (!tryMove(moveNode)) return;

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("type", "move_made");
        payload.put("move", jsonToObject(moveNode));
        send(player1, payload);
        send(player2, payload);

        if (isGameOver()) {
            ended = true;
            Map<String, Object> result = determineResult();
            Map<String, Object> overPayload = Map.of("type", "game_over", "result", result);
            send(player1, overPayload);
            send(player2, overPayload);
        }
    }

    private boolean tryMove(JsonNode moveNode) {
    try {
        if (moveNode.isTextual()) {
            // chesslib's Board.doMove(String) parses standard SAN
            // directly (e.g. "e4", "Nf3", "O-O") — no manual parsing needed.
            return board.doMove(moveNode.asText().trim());
        }

        if (moveNode.isObject()) {
            String from = moveNode.path("from").asText(null);
            String to = moveNode.path("to").asText(null);
            String promotion = moveNode.path("promotion").asText(null);
            if (from == null || to == null) return false;

            Square fromSq = Square.fromValue(from.toUpperCase());
            Square toSq = Square.fromValue(to.toUpperCase());
            Piece promoPiece = Piece.NONE;
            if (promotion != null && !promotion.isBlank()) {
                promoPiece = resolvePromotionPiece(promotion, board.getSideToMove());
            }

            Move move = new Move(fromSq, toSq, promoPiece);
            return board.doMove(move, true);
        }

        return false;
    } catch (Exception e) {
        return false;
    }
}

    private Piece resolvePromotionPiece(String code, Side side) {
        boolean white = side == Side.WHITE;
        return switch (code.toLowerCase()) {
            case "q" -> white ? Piece.WHITE_QUEEN : Piece.BLACK_QUEEN;
            case "r" -> white ? Piece.WHITE_ROOK : Piece.BLACK_ROOK;
            case "b" -> white ? Piece.WHITE_BISHOP : Piece.BLACK_BISHOP;
            case "n" -> white ? Piece.WHITE_KNIGHT : Piece.BLACK_KNIGHT;
            default -> Piece.NONE;
        };
    }

    private boolean isGameOver() {
        return board.isMated()
                || board.isStaleMate()
                || board.isInsufficientMaterial()
                || board.isRepetition()
                || board.getHalfMoveCounter() >= 100;
    }

    private Map<String, Object> determineResult() {
        Map<String, Object> result = new LinkedHashMap<>();
        if (board.isMated()) {
            String winner = board.getSideToMove() == Side.WHITE ? "black" : "white";
            result.put("winner", winner);
            result.put("reason", "checkmate");
        } else if (board.isStaleMate()) {
            result.put("winner", "draw");
            result.put("reason", "stalemate");
        } else if (board.isInsufficientMaterial()) {
            result.put("winner", "draw");
            result.put("reason", "insufficient_material");
        } else if (board.isRepetition()) {
            result.put("winner", "draw");
            result.put("reason", "threefold_repetition");
        } else if (board.getHalfMoveCounter() >= 100) {
            result.put("winner", "draw");
            result.put("reason", "50_move_rule");
        } else {
            result.put("winner", "draw");
            result.put("reason", "unknown");
        }
        return result;
    }

    public void handleVoiceRequest(WebSocketSession socket) {
        if (ended) return;
        pendingVoiceRequest = true;
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "voice_request"));
        log.info("Voice request sent to opponent");
    }

    public void handleVoiceResponse(WebSocketSession socket, JsonNode data) {
        if (ended || !pendingVoiceRequest) return;
        log.info("Voice response received: {}", data);
        if (data == null) {
            log.error("Invalid voice response data");
            return;
        }
        boolean accepted = data.path("accepted").asBoolean(false);
        voiceAvailable = accepted;
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "voice_response", "accepted", accepted));
        log.info("Voice response sent to opponent");
    }

    public void handleVideoRequest(WebSocketSession socket) {
        if (ended) return;
        pendingVideoRequest = true;
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "video_request"));
        log.info("Video request sent to opponent");
    }

    public void handleVideoResponse(WebSocketSession socket, JsonNode data) {
        if (ended || !pendingVideoRequest) {
            log.info("Video response received but game ended or no pending request");
            return;
        }
        log.info("Video response received: {}", data);
        if (data == null) {
            log.error("Invalid video response data");
            pendingVideoRequest = false;
            return;
        }
        boolean accepted = data.path("accepted").asBoolean(false);
        videoAvailable = accepted;
        pendingVideoRequest = false;
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "video_response", "accepted", accepted));
        log.info("Video response sent to opponent");
    }

    public void handleRtcOffer(WebSocketSession socket, JsonNode message) {
        if (ended) return;
        if (!voiceAvailable && !videoAvailable) return;
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "rtc_offer", "sdp", message.path("sdp").asText(null)));
        log.info("RTC offer sent to opponent");
    }

    public void handleRtcAnswer(WebSocketSession socket, JsonNode message) {
        if (ended) return;
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "rtc_answer", "sdp", message.path("sdp").asText(null)));
        log.info("RTC answer sent to opponent");
    }

    public void handleRtcIce(WebSocketSession socket, JsonNode message) {
        if (ended) return;
        if (!voiceAvailable && !videoAvailable) return;
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "rtc_ice", "candidate", jsonToObject(message.path("candidate"))));
        log.info("RTC ice sent to opponent");
    }

    public void handleMicToggle(WebSocketSession socket, JsonNode data) {
        if (ended) return;
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        send(opponent, Map.of("type", "mic_toggle", "enabled", data.path("enabled").asBoolean(false)));
        log.info("Mic toggle sent to opponent");
    }

    public void handleCameraToggle(WebSocketSession socket, JsonNode data) {
        if (ended) {
            log.info("Game has ended.");
            return;
        }
        WebSocketSession opponent = socket.equals(player1) ? player2 : player1;
        log.info("Camera toggle data: {}", data);
        send(opponent, Map.of("type", "camera_toggle", "enabled", data.path("enabled").asBoolean(false)));
        log.info("Camera toggle sent to opponent");
    }

    public void handleResign(WebSocketSession socket) {
        if (ended) return;
        ended = true;
        String winner = socket.equals(player1) ? "black" : "white";
        Map<String, Object> payload = Map.of(
                "type", "game_over",
                "result", Map.of("winner", winner, "reason", "resign"));
        send(player1, payload);
        send(player2, payload);
    }

    // ── helpers ──

    private void send(WebSocketSession session, Map<String, Object> payload) {
        try {
            if (session != null && session.isOpen()) {
                session.sendMessage(new TextMessage(mapper.writeValueAsString(payload)));
            }
        } catch (Exception e) {
            log.error("opponent socket is closed or not available");
        }
    }

    private Object jsonToObject(JsonNode node) {
        try {
            return mapper.treeToValue(node, Object.class);
        } catch (Exception e) {
            return null;
        }
    }
}
