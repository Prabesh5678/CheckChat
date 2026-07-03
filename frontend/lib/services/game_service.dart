import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:chess/chess.dart' as chess_lib;

import 'webrtc_service.dart';

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

  GameService() {
    webrtcService = _newWebrtcService();
  }

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

  // ── RTC (voice/video) state ──
  //
  // `webrtcService` is swapped out for a brand new instance every time a
  // session ends (game over / opponent disconnect / rematch), because
  // WebRTCService.teardown() calls the underlying ChangeNotifier.dispose(),
  // which is one-way — the old instance can never be reused. GameService
  // itself outlives many game sessions (e.g. across "Play Again"), so it
  // always holds a live, ready-to-use WebRTCService.
  late WebRTCService webrtcService;

  WebRTCService _newWebrtcService() {
    return WebRTCService(
      sendMessage: (type, data) => _send({'type': type, ...data}),
    );
  }

  bool voiceAccepted = false;
  bool videoAccepted = false;
  bool incomingVoiceRequest = false;
  bool incomingVideoRequest = false;

  // Whether *we* sent the request — this is how we know, when the
  // corresponding *_response arrives accepted, that we're the offerer.
  bool _sentVoiceRequest = false;
  bool _sentVideoRequest = false;
  bool get sentVoiceRequest => _sentVoiceRequest;
  bool get sentVideoRequest => _sentVideoRequest;

  // Opponent's reported mic/camera state (pure UI signal — a disabled
  // sender-side track already stops delivering media, so we don't need to
  // touch our copy of the remote track for this; it just drives icons and
  // the "camera off" placeholder in VideoView).
  bool opponentMicOn = true;
  bool opponentCameraOn = true;

  // Local mic/camera enabled state lives on webrtcService (it's the thing
  // actually flipping track.enabled); these are thin passthrough getters so
  // widgets only need to read `game.micOn` / `game.cameraOn`.
  bool get micOn => webrtcService.micEnabled;
  bool get cameraOn => webrtcService.cameraEnabled;

  // Speaker routing is device-local only — there's no speaker_toggle
  // message type, the opponent never needs to know about it.
  bool _speakerOn = true;
  bool get speakerOn => _speakerOn;

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
        _teardownRtc();
        notifyListeners();
      },
      onDone: () {
        if (status != GameStatus.gameOver) {
          status = GameStatus.disconnected;
          _teardownRtc();
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
        // A fresh pairing means any RTC session from a previous match (if
        // any) is definitely stale — make sure we start clean.
        _resetRtcFlags();
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
        _teardownRtc();
        notifyListeners();
        break;

      case 'opponent_disconnected':
        winner = color;
        gameOverReason = 'opponent_disconnected';
        status = GameStatus.gameOver;
        _teardownRtc();
        notifyListeners();
        break;

      case 'chat':
        messages.add(ChatMessage(msg['from'], msg['message']));
        notifyListeners();
        break;

      // ── voice / video signaling ──

      case 'voice_request':
        incomingVoiceRequest = true;
        notifyListeners();
        break;

      case 'voice_response':
        unawaited(_handleVoiceResponse(msg));
        break;

      case 'video_request':
        incomingVideoRequest = true;
        notifyListeners();
        break;

      case 'video_response':
        unawaited(_handleVideoResponse(msg));
        break;

      case 'rtc_offer':
        unawaited(
          webrtcService.handleRemoteOffer(
            Map<String, dynamic>.from(msg['sdp']),
          ),
        );
        break;

      case 'rtc_answer':
        unawaited(
          webrtcService.handleRemoteAnswer(
            Map<String, dynamic>.from(msg['sdp']),
          ),
        );
        break;

      case 'rtc_ice':
        unawaited(
          webrtcService.handleRemoteIceCandidate(
            Map<String, dynamic>.from(msg['candidate']),
          ),
        );
        break;

      case 'mic_toggle':
        opponentMicOn = msg['enabled'] == true;
        notifyListeners();
        break;

      case 'camera_toggle':
        opponentCameraOn = msg['enabled'] == true;
        notifyListeners();
        break;
    }
  }

  // ── voice / video: outgoing requests ──

  void requestVoice() {
    if (_sentVoiceRequest || voiceAccepted) return;
    _sentVoiceRequest = true;
    _send({'type': 'voice_request'});
    notifyListeners();
  }

  void requestVideo() {
    if (_sentVideoRequest || videoAccepted) return;
    _sentVideoRequest = true;
    _send({'type': 'video_request'});
    notifyListeners();
  }

  // ── voice / video: responding to an incoming request ──

  Future<void> respondToVoiceRequest(bool accepted) async {
    incomingVoiceRequest = false;
    _send({'type': 'voice_response', 'accepted': accepted});
    if (accepted) {
      voiceAccepted = true;
      // We're the answerer for this round — get our mic ready and then
      // just wait for the requester's rtc_offer.
      notifyListeners();
      await webrtcService.startLocalMedia(withVideo: false);
    }
    notifyListeners();
  }

  Future<void> respondToVideoRequest(bool accepted) async {
    incomingVideoRequest = false;
    _send({'type': 'video_response', 'accepted': accepted});
    if (accepted) {
      videoAccepted = true;
      voiceAccepted = true; // video implies audio — see class-level note
      notifyListeners();
      await webrtcService.startLocalMedia(withVideo: true);
    }
    notifyListeners();
  }

  // ── voice / video: handling the response to OUR request ──

  Future<void> _handleVoiceResponse(Map<String, dynamic> msg) async {
    final accepted = msg['accepted'] == true;
    final wasRequester = _sentVoiceRequest;
    _sentVoiceRequest = false;

    if (!accepted) {
      voiceAccepted = false;
      notifyListeners();
      return;
    }

    voiceAccepted = true;
    if (wasRequester) {
      // voice_response only reaches the original requester (backend
      // forwards B's answer to A) — so if we sent the request, we're A,
      // and we become the offerer now that B has accepted.
      await webrtcService.startLocalMedia(withVideo: false);
      await webrtcService.createAndSendOffer();
    }
    notifyListeners();
  }

  Future<void> _handleVideoResponse(Map<String, dynamic> msg) async {
    final accepted = msg['accepted'] == true;
    final wasRequester = _sentVideoRequest;
    _sentVideoRequest = false;

    if (!accepted) {
      notifyListeners();
      return;
    }

    videoAccepted = true;
    voiceAccepted = true;
    // Rebuild immediately so the button leaves `Requested…` even while
    // local media / offer setup is still in progress.
    notifyListeners();
    if (wasRequester) {
      await webrtcService.startLocalMedia(withVideo: true);
      // If voice was already active, the peer connection already exists
      // and this addTrack requires renegotiation — createAndSendOffer()
      // handles that the same way whether it's the first offer ever or a
      // renegotiation on top of an existing connection.
      await webrtcService.createAndSendOffer();
    }
    notifyListeners();
  }

  // ── voice / video: local toggles ──

  void toggleMic() {
    final newState = !webrtcService.micEnabled;
    webrtcService.setMicEnabled(newState);
    _send({'type': 'mic_toggle', 'enabled': newState});
    notifyListeners();
  }

  void toggleCamera() {
    final newState = !webrtcService.cameraEnabled;
    webrtcService.setCameraEnabled(newState);
    _send({'type': 'camera_toggle', 'enabled': newState});
    notifyListeners();
  }

  void toggleSpeaker() {
    _speakerOn = !_speakerOn;
    webrtcService.setSpeakerEnabled(_speakerOn);
    // Helper.setSpeakerphoneOn is a mobile-only audio routing API; on web
    // the browser/OS handles output routing itself.
    if (!kIsWeb) {
      Helper.setSpeakerphoneOn(_speakerOn);
    }
    notifyListeners();
  }

  void _resetRtcFlags() {
    voiceAccepted = false;
    videoAccepted = false;
    incomingVoiceRequest = false;
    incomingVideoRequest = false;
    _sentVoiceRequest = false;
    _sentVideoRequest = false;
    opponentMicOn = true;
    opponentCameraOn = true;
  }

  /// Tears down the current RTC session (per design rule: destroy the peer
  /// connection when the game ends or the opponent disconnects) and swaps
  /// in a fresh WebRTCService so GameService is immediately ready for a
  /// possible next game (rematch).
  void _teardownRtc() {
    _resetRtcFlags();
    final old = webrtcService;
    webrtcService = _newWebrtcService();
    unawaited(old.teardown());
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
    // New init_game can pair us with a different opponent entirely, so any
    // in-progress RTC session must not carry over.
    _teardownRtc();
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
    unawaited(webrtcService.teardown());
    _channel?.sink.close();
    super.dispose();
  }
}
