import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:chess/chess.dart' as chess_lib;

// Same WS_URL pattern as your React app — swap for production URL
const String wsUrl = String.fromEnvironment(
  'WS_URL',
  defaultValue: 'ws://localhost:8080',
);

enum GameStatus { connecting, waiting, playing, gameOver, error, disconnected }

class ChatMessage {
  final String from; // "white" | "black"
  final String text;
  ChatMessage(this.from, this.text);
}

/// Mirrors the state + refs pattern from Game.jsx.
/// ChangeNotifier == React state (drives UI rebuilds).
/// Plain fields == refs (always current, read inside handlers).
class GameService extends ChangeNotifier {
  WebSocketChannel? _channel;
  final chess_lib.Chess board = chess_lib.Chess();

  GameStatus status = GameStatus.connecting;
  String? color; // "white" | "black"
  String? winner;
  String? gameOverReason;
  bool promotionPending = false;
  Map<String, String>? pendingPromotion; // {from, to}

  String? selected;
  List<String> legalSquares = [];

  // last move played — used for chess.com-style highlight
  String? lastMoveFrom;
  String? lastMoveTo;

  final List<ChatMessage> messages = [];

  // returns true if the side-to-move is in check
  bool get inCheck => board.in_check;

  // returns the square of the king that is currently in check, or null
  String? get kingInCheckSquare {
    if (!inCheck) return null;
    final kingColor = board.turn; // side to move is the one in check
    for (final file in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
      for (final rank in ['1', '2', '3', '4', '5', '6', '7', '8']) {
        final sq = file + rank;
        final p = board.get(sq);
        if (p != null &&
            p.type == chess_lib.PieceType.KING &&
            p.color == kingColor) {
          return sq;
        }
      }
    }
    return null;
  }

  void connect() {
    status = GameStatus.connecting;
    notifyListeners();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    } catch (e) {
      status = GameStatus.error;
      notifyListeners();
      return;
    }

    _channel!.sink.add(jsonEncode({'type': 'init_game'}));
    status = GameStatus.waiting;
    notifyListeners();

    _channel!.stream.listen(
      _onMessage,
      onError: (_) {
        status = GameStatus.error;
        notifyListeners();
      },
      onDone: () {
        if (status != GameStatus.gameOver) {
          status = GameStatus.disconnected;
          notifyListeners();
        }
      },
    );
  }

  void _onMessage(dynamic data) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data);
    } catch (_) {
      return;
    }

    switch (msg['type']) {
      case 'game_start':
        color = msg['color'];
        board.reset();
        selected = null;
        legalSquares = [];
        pendingPromotion = null;
        promotionPending = false;
        winner = null;
        gameOverReason = null;
        lastMoveFrom = null;
        lastMoveTo = null;
        messages.clear();
        status = GameStatus.playing;
        notifyListeners();
        break;

      case 'move_made':
        final move = msg['move'];
        final ok = board.move({
          'from': move['from'],
          'to': move['to'],
          if (move['promotion'] != null) 'promotion': move['promotion'],
        });
        if (ok) {
          lastMoveFrom = move['from'];
          lastMoveTo = move['to'];
          selected = null;
          legalSquares = [];
          notifyListeners();
        }
        break;

      case 'game_over':
        winner = msg['result']['winner'];
        gameOverReason = msg['result']['reason'];
        status = GameStatus.gameOver;
        notifyListeners();
        break;

      case 'opponent_disconnected':
        winner = color;
        gameOverReason = 'opponent_disconnected';
        status = GameStatus.gameOver;
        notifyListeners();
        break;

      case 'chat':
        messages.add(ChatMessage(msg['from'], msg['message']));
        notifyListeners();
        break;
    }
  }

  // ── moves ──

  String get myColorCode => color == 'white' ? 'w' : 'b';

  bool get myTurn =>
      status == GameStatus.playing &&
      board.turn ==
          (myColorCode == 'w' ? chess_lib.Color.WHITE : chess_lib.Color.BLACK);

  void selectSquare(String sq) {
    if (status != GameStatus.playing || promotionPending) return;
    if (!myTurn) return;

    if (selected != null) {
      if (selected == sq) {
        selected = null;
        legalSquares = [];
        notifyListeners();
        return;
      }
      if (legalSquares.contains(sq)) {
        _tryMove(selected!, sq);
        return;
      }
      final piece = board.get(sq);
      if (piece != null &&
          piece.color ==
              (myColorCode == 'w'
                  ? chess_lib.Color.WHITE
                  : chess_lib.Color.BLACK)) {
        _selectPiece(sq);
        return;
      }
      selected = null;
      legalSquares = [];
      notifyListeners();
      return;
    }

    final piece = board.get(sq);
    if (piece == null) return;
    _selectPiece(sq);
  }

  void _selectPiece(String sq) {
    selected = sq;
    legalSquares = _legalTargets(sq);
    notifyListeners();
  }

  List<String> _legalTargets(String sq) {
    final moves = board.generate_moves({'square': sq, 'verbose': true});
    return moves.map<String>((m) {
      final dynamic move = m;
      // chess package versions expose the target square under different
      // field names depending on version — try the common ones in order.
      try {
        return move.toAlgebraic.toString();
      } catch (_) {}
      try {
        return move.to.toString();
      } catch (_) {}
      try {
        return move['to'].toString();
      } catch (_) {}
      // last resort — parse it out of the move's string representation
      return move.toString();
    }).toList();
  }

  bool _isPromotionMove(String from, String to) {
    final piece = board.get(from);
    if (piece == null || piece.type != chess_lib.PieceType.PAWN) return false;
    final toRank = to[1];
    final isWhite = piece.color == chess_lib.Color.WHITE;
    return (isWhite && toRank == '8') || (!isWhite && toRank == '1');
  }

  void _tryMove(String from, String to) {
    if (!legalSquares.contains(to)) return;

    if (_isPromotionMove(from, to)) {
      pendingPromotion = {'from': from, 'to': to};
      promotionPending = true;
      notifyListeners();
      return;
    }

    _send({
      'type': 'move',
      'move': {'from': from, 'to': to},
    });
    selected = null;
    legalSquares = [];
    notifyListeners();
  }

  // public entry for drag-and-drop drop target
  void attemptMove(String from, String to) {
    if (status != GameStatus.playing || promotionPending) return;
    if (!myTurn) return;
    final targets = _legalTargets(from);
    if (!targets.contains(to)) return;
    legalSquares = targets;
    _tryMove(from, to);
  }

  bool canDrag(String sq) {
    if (status != GameStatus.playing || promotionPending) return false;
    if (!myTurn) return false;
    final piece = board.get(sq);
    if (piece == null) return false;
    final myColor =
        myColorCode == 'w' ? chess_lib.Color.WHITE : chess_lib.Color.BLACK;
    return piece.color == myColor;
  }

  void choosePromotion(String pieceKey) {
    final pending = pendingPromotion;
    if (pending == null) return;
    _send({
      'type': 'move',
      'move': {
        'from': pending['from'],
        'to': pending['to'],
        'promotion': pieceKey
      },
    });
    pendingPromotion = null;
    promotionPending = false;
    selected = null;
    legalSquares = [];
    notifyListeners();
  }

  // ── chat ──

  void sendChat(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || status != GameStatus.playing) return;
    _send({'type': 'chat', 'message': trimmed});
  }

  // ── rematch ──

  void playAgain() {
    board.reset();
    winner = null;
    gameOverReason = null;
    selected = null;
    legalSquares = [];
    pendingPromotion = null;
    promotionPending = false;
    lastMoveFrom = null;
    lastMoveTo = null;
    status = GameStatus.waiting;
    notifyListeners();
    _send({'type': 'init_game'});
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }
}
