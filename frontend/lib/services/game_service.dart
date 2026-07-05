import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:chess/chess.dart' as chess_lib;
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'webrtc_service.dart';

final wsUrl = dotenv.env['WS_URL']!;
// Same WS_URL pattern as your React app — swap for production URL
// const String wsUrl = String.fromEnvironment(
//   'WS_URL',
//   defaultValue: 'wss://checkchat.azurewebsites.net',
// );

enum GameStatus { connecting, waiting, playing, gameOver, error, disconnected }

class ChatMessage {
  final String from; // "white" | "black"
  final String text;
  ChatMessage(this.from, this.text);
}

/// Mirrors the state + refs pattern from Game.jsx.
/// ChangeNotifier == React state (drives UI rebuilds).
/// Plain fields == refs (always current, read inside handlers).
///
/// Every signaling step logs through [_log], tagged with platform (web /
/// android / ios / etc) — combined with the matching logs in
/// WebRTCService, this lets you grep both peers' console output side by
/// side and find exactly where the two sides' logs diverge. That
/// divergence point is where the connection is actually breaking.
class GameService extends ChangeNotifier {
  WebSocketChannel? _channel;
  final chess_lib.Chess board = chess_lib.Chess();

  GameService() {
    webrtcService = _newWebrtcService();
  }

  static String get _platformTag =>
      kIsWeb ? 'web' : defaultTargetPlatform.toString().split('.').last;

  void _log(String message) {
    debugPrint('[RTC][GameService][$_platformTag] $message');
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
    _log('creating new WebRTCService instance');
    final service = WebRTCService(
      sendMessage: (type, data) {
        _log('sending signaling message: $type $data');
        _send({'type': type, ...data});
      },
    );
    // forward any WebRTCService state change up to GameService listeners
    // so VideoView rebuilds immediately when remote stream arrives
    service.addListener(() => notifyListeners());
    return service;
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
    _log('connect() — connecting to $wsUrl');
    status = GameStatus.connecting;
    notifyListeners();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    } catch (e) {
      _log('WebSocketChannel.connect FAILED: $e');
      status = GameStatus.error;
      notifyListeners();
      return;
    }

    _channel!.sink.add(jsonEncode({'type': 'init_game'}));
    _log('sent init_game, entering waiting state');
    status = GameStatus.waiting;
    notifyListeners();

    _channel!.stream.listen(
      _onMessage,
      onError: (e) {
        _log('WebSocket stream onError: $e — tearing down RTC');
        status = GameStatus.error;
        _teardownRtc();
        notifyListeners();
      },
      onDone: () {
        _log('WebSocket stream onDone (status was $status)');
        if (status != GameStatus.gameOver) {
          _log('onDone while not gameOver — treating as disconnect, '
              'tearing down RTC');
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
    } catch (e) {
      _log('failed to decode incoming message: $e — raw data: $data');
      return;
    }

    _log('◀ received: ${msg['type']} $msg');

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
        _log('game_start: paired as $color — resetting RTC flags for a '
            'fresh session');
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
        _log('game_over ($gameOverReason) — tearing down RTC');
        _teardownRtc();
        notifyListeners();
        break;

      case 'opponent_disconnected':
        winner = color;
        gameOverReason = 'opponent_disconnected';
        status = GameStatus.gameOver;
        _log('opponent_disconnected — tearing down RTC');
        _teardownRtc();
        notifyListeners();
        break;

      case 'chat':
        messages.add(ChatMessage(msg['from'], msg['message']));
        notifyListeners();
        break;

      // ── voice / video signaling ──

      case 'voice_request':
        _log('incoming voice_request — showing dialog');
        incomingVoiceRequest = true;
        notifyListeners();
        break;

      case 'voice_response':
        _log('voice_response received: accepted=${msg['accepted']}, '
            'wasRequester=$_sentVoiceRequest');
        unawaited(_handleVoiceResponse(msg));
        break;

      case 'video_request':
        _log('incoming video_request — showing dialog');
        incomingVideoRequest = true;
        notifyListeners();
        break;

      case 'video_response':
        _log('video_response received: accepted=${msg['accepted']}, '
            'wasRequester=$_sentVideoRequest');
        unawaited(_handleVideoResponse(msg));
        break;

      case 'rtc_offer':
        _log('rtc_offer received — delegating to webrtcService');
        unawaited(
          webrtcService.handleRemoteOffer(
            Map<String, dynamic>.from(msg['sdp']),
          ),
        );
        break;

      case 'rtc_answer':
        _log('rtc_answer received — delegating to webrtcService');
        unawaited(
          webrtcService.handleRemoteAnswer(
            Map<String, dynamic>.from(msg['sdp']),
          ),
        );
        break;

      case 'rtc_ice':
        _log('rtc_ice received — delegating to webrtcService');
        unawaited(
          webrtcService.handleRemoteIceCandidate(
            Map<String, dynamic>.from(msg['candidate']),
          ),
        );
        break;

      case 'mic_toggle':
        opponentMicOn = msg['enabled'] == true;
        _log('opponent mic_toggle: opponentMicOn=$opponentMicOn');
        notifyListeners();
        break;

      case 'camera_toggle':
        opponentCameraOn = msg['enabled'] == true;
        _log('opponent camera_toggle: opponentCameraOn=$opponentCameraOn');
        notifyListeners();
        break;

      default:
        _log('unhandled message type: ${msg['type']}');
    }
  }

  // ── voice / video: outgoing requests ──

  void requestVoice() {
    if (_sentVoiceRequest || voiceAccepted) {
      _log('requestVoice() ignored — already requested or accepted');
      return;
    }
    _log('requestVoice() — sending voice_request');
    _sentVoiceRequest = true;
    _send({'type': 'voice_request'});
    notifyListeners();
  }

  void requestVideo() {
    if (_sentVideoRequest || videoAccepted) {
      _log('requestVideo() ignored — already requested or accepted');
      return;
    }
    _log('requestVideo() — sending video_request');
    _sentVideoRequest = true;
    _send({'type': 'video_request'});
    notifyListeners();
  }
  void resign() {
    if (status != GameStatus.playing) return;
    _log('resign() — sending resign');
    _send({'type': 'resign'});
  }

  void cancelWaiting() {
    if (status != GameStatus.waiting) return;
    _log('cancelWaiting() — sending cancel_wait');
    _send({'type': 'cancel_wait'});
    status = GameStatus.disconnected;
    notifyListeners();
  }
  // ── voice / video: responding to an incoming request ──

  Future<void> respondToVoiceRequest(bool accepted) async {
    _log('respondToVoiceRequest(accepted: $accepted)');
    incomingVoiceRequest = false;
    _send({'type': 'voice_response', 'accepted': accepted});
    if (accepted) {
      voiceAccepted = true;
      // We're the answerer for this round — get our mic ready and then
      // just wait for the requester's rtc_offer.
      notifyListeners();
      _log('answerer role: starting local audio media, then waiting for '
          'rtc_offer');
      await webrtcService.startLocalMedia(withVideo: false);
    }
    notifyListeners();
  }

  Future<void> respondToVideoRequest(bool accepted) async {
    _log('respondToVideoRequest(accepted: $accepted)');
    incomingVideoRequest = false;
    _send({'type': 'video_response', 'accepted': accepted});
    if (accepted) {
      videoAccepted = true;
      voiceAccepted = true; // video implies audio — see class-level note
      notifyListeners();
      _log('answerer role: starting local audio+video media, then waiting '
          'for rtc_offer');
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
      _log('voice request was declined');
      voiceAccepted = false;
      notifyListeners();
      return;
    }

    voiceAccepted = true;
    if (wasRequester) {
      // voice_response only reaches the original requester (backend
      // forwards B's answer to A) — so if we sent the request, we're A,
      // and we become the offerer now that B has accepted.
      _log('offerer role: starting local audio media, then creating offer');
      await webrtcService.startLocalMedia(withVideo: false);
      await webrtcService.createAndSendOffer();
    } else {
      _log('voice_response accepted but we were not the requester — '
          'unexpected, ignoring offerer role');
    }
    notifyListeners();
  }

  Future<void> _handleVideoResponse(Map<String, dynamic> msg) async {
    final accepted = msg['accepted'] == true;
    final wasRequester = _sentVideoRequest;
    _sentVideoRequest = false;

    if (!accepted) {
      _log('video request was declined');
      notifyListeners();
      return;
    }

    videoAccepted = true;
    voiceAccepted = true;
    // Rebuild immediately so the button leaves `Requested…` even while
    // local media / offer setup is still in progress.
    notifyListeners();
    if (wasRequester) {
      _log('offerer role: starting local audio+video media, then creating '
          '(re)offer');
      await webrtcService.startLocalMedia(withVideo: true);
      // If voice was already active, the peer connection already exists
      // and this addTrack requires renegotiation — createAndSendOffer()
      // handles that the same way whether it's the first offer ever or a
      // renegotiation on top of an existing connection.
      await webrtcService.createAndSendOffer();
    } else {
      _log('video_response accepted but we were not the requester — '
          'unexpected, ignoring offerer role');
    }
    notifyListeners();
  }

  // ── voice / video: local toggles ──

  void toggleMic() {
    final newState = !webrtcService.micEnabled;
    _log('toggleMic() -> $newState');
    webrtcService.setMicEnabled(newState);
    _send({'type': 'mic_toggle', 'enabled': newState});
    notifyListeners();
  }

  void toggleCamera() {
    final newState = !webrtcService.cameraEnabled;
    _log('toggleCamera() -> $newState');
    webrtcService.setCameraEnabled(newState);
    _send({'type': 'camera_toggle', 'enabled': newState});
    notifyListeners();
  }

  void toggleSpeaker() {
    _speakerOn = !_speakerOn;
    _log('toggleSpeaker() -> $_speakerOn');
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
    _log('_teardownRtc() called');
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
    _log('playAgain() — tearing down RTC before requeueing');
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
    _log('dispose() — tearing down RTC and closing socket');
    unawaited(webrtcService.teardown());
    _channel?.sink.close();
    super.dispose();
  }
}
