package com.chess.backend.chess;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.WebSocketSession;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Singleton Spring bean, matching the module-level singleton in the
 * Node/Django versions. Matchmaking state lives in memory for a single
 * process — same assumption those versions made. If you ever run multiple
 * instances behind a load balancer, this needs to move to a shared store
 * instead of in-process fields.
 */
@Component
public class GameManager {

    private static final Logger log = LoggerFactory.getLogger(GameManager.class);

    private final List<WebSocketSession> users = new CopyOnWriteArrayList<>();
    private final List<Game> games = new CopyOnWriteArrayList<>();
    private volatile WebSocketSession pendingUser;
    private final ObjectMapper mapper = new ObjectMapper();

    public void addPlayer(WebSocketSession session) {
        users.add(session);
    }

    private Game findGame(WebSocketSession session) {
        for (Game game : games) {
            if (game.getPlayer1().equals(session) || game.getPlayer2().equals(session)) {
                return game;
            }
        }
        return null;
    }

    public synchronized void removePlayer(WebSocketSession session) {
        users.remove(session);
        if (session.equals(pendingUser)) {
            pendingUser = null;
        }

        Game game = findGame(session);
        if (game != null) {
            game.notifyOpponentLeft(session);
            games.remove(game);
        }
    }

    public synchronized void handleMessage(WebSocketSession socket, String rawData) {
        JsonNode message;
        try {
            message = mapper.readTree(rawData);
        } catch (Exception e) {
            return;
        }

        String type = message.path("type").asText(null);
        if (type == null) return;

        if (type.equals("rtc_offer") || type.equals("rtc_answer") || type.equals("rtc_ice")) {
            log.info("[RTC][GameManager] incoming {} hasSdp={} hasCandidate={}",
                    type, message.has("sdp"), message.has("candidate"));
        }

        switch (type) {
            case "init_game" -> {
                Game existing = findGame(socket);
                if (existing != null) {
                    games.remove(existing);
                }
                if (pendingUser != null && !pendingUser.equals(socket)) {
                    Game game = new Game(pendingUser, socket);
                    games.add(game);
                    pendingUser = null;
                    game.start();
                } else {
                    pendingUser = socket;
                }
            }

            case "move" -> {
                Game game = findGame(socket);
                if (game != null) game.makeMove(socket, message.path("move"));
            }

            case "chat" -> {
                Game game = findGame(socket);
                if (game != null) game.sendChat(socket, message.path("message").asText(null));
            }

            case "voice_request" -> {
                Game game = findGame(socket);
                if (game != null) game.handleVoiceRequest(socket);
            }

            case "voice_response" -> {
                Game game = findGame(socket);
                if (game != null) game.handleVoiceResponse(socket, message);
            }

            case "video_request" -> {
                Game game = findGame(socket);
                if (game != null) game.handleVideoRequest(socket);
            }

            case "video_response" -> {
                Game game = findGame(socket);
                if (game != null) game.handleVideoResponse(socket, message);
            }

            case "rtc_offer" -> {
                Game game = findGame(socket);
                if (game == null) {
                    log.info("[RTC][GameManager] no game found for rtc_offer");
                } else {
                    game.handleRtcOffer(socket, message);
                }
            }

            case "rtc_answer" -> {
                Game game = findGame(socket);
                if (game == null) {
                    log.info("[RTC][GameManager] no game found for rtc_answer");
                } else {
                    game.handleRtcAnswer(socket, message);
                }
            }

            case "mic_toggle" -> {
                log.info("Received mic toggle message");
                Game game = findGame(socket);
                if (game == null) {
                    log.info("Game not found for mic toggle");
                } else {
                    game.handleMicToggle(socket, message);
                }
            }

            case "camera_toggle" -> {
                log.info("Received camera toggle message");
                Game game = findGame(socket);
                if (game == null) {
                    log.info("Game not found for camera toggle");
                } else {
                    game.handleCameraToggle(socket, message);
                }
            }

            case "rtc_ice" -> {
                Game game = findGame(socket);
                if (game == null) {
                    log.info("[RTC][GameManager] no game found for rtc_ice");
                } else {
                    game.handleRtcIce(socket, message);
                }
            }

            case "resign" -> {
                Game game = findGame(socket);
                if (game != null) game.handleResign(socket);
            }

            case "cancel_wait" -> {
                if (socket.equals(pendingUser)) {
                    pendingUser = null;
                }
            }

            default -> { /* unknown message type, ignore */ }
        }
    }
}
