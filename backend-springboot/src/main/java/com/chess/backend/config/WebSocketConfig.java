package com.chess.backend.config;

import com.chess.backend.chess.ChessWebSocketHandler;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

@Configuration
@EnableWebSocket
public class WebSocketConfig implements WebSocketConfigurer {

    private final ChessWebSocketHandler chessWebSocketHandler;

    public WebSocketConfig(ChessWebSocketHandler chessWebSocketHandler) {
        this.chessWebSocketHandler = chessWebSocketHandler;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        // Registered at the bare root ("/") on purpose: the frontend's
        // WS_URL has no path component (ws://host:port), same requirement
        // that came up with the Django port. This mirrors the original
        // `new WebSocketServer({ server })`, which never checked the path.
        registry.addHandler(chessWebSocketHandler, "/").setAllowedOrigins("*");
    }
}
