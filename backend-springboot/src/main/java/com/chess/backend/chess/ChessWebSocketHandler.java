package com.chess.backend.chess;

import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

@Component
public class ChessWebSocketHandler extends TextWebSocketHandler {

    private final GameManager gameManager;

    public ChessWebSocketHandler(GameManager gameManager) {
        this.gameManager = gameManager;
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        gameManager.addPlayer(session);
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) {
        gameManager.handleMessage(session, message.getPayload());
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        gameManager.removePlayer(session);
    }
}
