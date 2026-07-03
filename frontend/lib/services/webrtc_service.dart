import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Manages the single RTCPeerConnection for the lifetime of a game session.
///
/// This service knows nothing about WebSockets directly — it is handed a
/// [sendMessage] callback by GameService so it can push rtc_offer / rtc_answer
/// / rtc_ice payloads out over the existing socket without creating a
/// circular import between game_service.dart and webrtc_service.dart.
///
/// Design invariants (do not violate these when editing):
///  - Exactly one RTCPeerConnection is created per game session. It is never
///    torn down and recreated for mic/camera toggles.
///  - Toggling mic/camera only flips `track.enabled` on the already-published
///    local tracks. That is a local-only operation and requires NO
///    renegotiation, no new offer/answer.
///  - The only time we renegotiate (new createOffer/setLocalDescription) is
///    when a track is added that didn't exist before — i.e. upgrading from
///    voice-only to voice+video. Toggling video off later just disables the
///    track; it does not remove it or renegotiate again.
///  - dispose() must be called when the game ends or the opponent
///    disconnects, and only then.
class WebRTCService extends ChangeNotifier {
  WebRTCService({required this.sendMessage});

  /// Sends a signaling message over the existing game WebSocket.
  /// Signature matches GameService's internal `_send(type, data)` helper.
  final void Function(String type, Map<String, dynamic> data) sendMessage;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  bool _hasVideoTrack = false;
  bool _micEnabled = true;
  bool _cameraEnabled = true;

  // ICE candidates that arrive before we have a remote description yet
  // (e.g. opponent's candidates trickling in before our answer is set).
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  bool _remoteDescriptionSet = false;

  bool get hasPeerConnection => _pc != null;
  bool get hasVideoTrack => _hasVideoTrack;
  bool get micEnabled => _micEnabled;
  bool get cameraEnabled => _cameraEnabled;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  static const Map<String, dynamic> _iceServersConfig = {
    'iceServers': [
      {
        'urls': ['stun:stun.l.google.com:19302'],
      },
      // TODO: add a TURN server here before shipping to production.
      // STUN alone will fail for players behind symmetric NATs / strict
      // corporate firewalls, which is common enough that voice/video will
      // silently fail to connect for some fraction of real users.
    ],
  };

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  Future<void> _ensurePeerConnection() async {
    if (_pc != null) return;

    _pc = await createPeerConnection(_iceServersConfig);

    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null) return;
      sendMessage('rtc_ice', {
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    _pc!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        remoteRenderer.srcObject = _remoteStream;
        notifyListeners();
      }
    };

    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      // Surface state changes so UI (e.g. a "connecting…" indicator) can
      // react if desired. We deliberately do NOT auto-dispose here on
      // failure/disconnected — GameService decides lifecycle based on the
      // actual game/opponent-connection state, not transient ICE hiccups.
      notifyListeners();
    };

    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      notifyListeners();
    };
  }

  /// Grabs local mic (+ camera if [withVideo]) and publishes tracks onto the
  /// single shared peer connection. Safe to call twice: the second call with
  /// withVideo=true after an audio-only call will just add the video track
  /// on top of the existing audio track (upgrade path), it will not recreate
  /// the audio track or the connection.
  Future<void> startLocalMedia({required bool withVideo}) async {
    await _ensureRenderers();
    await _ensurePeerConnection();

    final bool needsAudio = _localStream == null;
    final bool needsVideo = withVideo && !_hasVideoTrack;

    if (!needsAudio && !needsVideo) {
      // Nothing new to publish.
      return;
    }

    if (_localStream == null) {
      // First time: grab audio (always) + video (if requested up front).
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': withVideo
            ? {
                'facingMode': 'user',
                'width': {'ideal': 640},
                'height': {'ideal': 480},
              }
            : false,
      });
      _localStream = stream;
      localRenderer.srcObject = stream;

      for (final track in stream.getTracks()) {
        await _pc!.addTrack(track, stream);
      }
      _hasVideoTrack = withVideo && stream.getVideoTracks().isNotEmpty;
    } else if (needsVideo) {
      // Upgrade path: voice was already active, now add video on top of the
      // existing stream/connection. This is the one case that requires
      // renegotiation — handled by the caller re-running the offer flow
      // after this returns (see GameService's video-accepted handler).
      final videoStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': 'user',
          'width': {'ideal': 640},
          'height': {'ideal': 480},
        },
      });
      final videoTrack = videoStream.getVideoTracks().first;
      _localStream!.addTrack(videoTrack);
      localRenderer.srcObject = _localStream;
      await _pc!.addTrack(videoTrack, _localStream!);
      _hasVideoTrack = true;
    }

    notifyListeners();
  }

  /// Called by the peer whose request (voice or video) was just accepted.
  /// That peer becomes the offerer for this negotiation round.
  Future<void> createAndSendOffer() async {
    await _ensurePeerConnection();
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    sendMessage('rtc_offer', {
      'sdp': {'sdp': offer.sdp, 'type': offer.type},
    });
  }

  /// Handles an incoming offer (we are the answerer for this round).
  Future<void> handleRemoteOffer(Map<String, dynamic> sdpMap) async {
    await _ensurePeerConnection();
    final desc = RTCSessionDescription(sdpMap['sdp'], sdpMap['type']);
    await _pc!.setRemoteDescription(desc);
    _remoteDescriptionSet = true;
    await _drainPendingCandidates();

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    sendMessage('rtc_answer', {
      'sdp': {'sdp': answer.sdp, 'type': answer.type},
    });
  }

  /// Handles an incoming answer (we are the offerer for this round).
  Future<void> handleRemoteAnswer(Map<String, dynamic> sdpMap) async {
    if (_pc == null) return;
    final desc = RTCSessionDescription(sdpMap['sdp'], sdpMap['type']);
    await _pc!.setRemoteDescription(desc);
    _remoteDescriptionSet = true;
    await _drainPendingCandidates();
  }

  Future<void> handleRemoteIceCandidate(
      Map<String, dynamic> candidateMap) async {
    final candidate = RTCIceCandidate(
      candidateMap['candidate'],
      candidateMap['sdpMid'],
      candidateMap['sdpMLineIndex'],
    );

    if (_pc == null || !_remoteDescriptionSet) {
      // Queue until we have a remote description to attach it to.
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    await _pc!.addCandidate(candidate);
  }

  Future<void> _drainPendingCandidates() async {
    if (_pc == null) return;
    for (final c in _pendingRemoteCandidates) {
      await _pc!.addCandidate(c);
    }
    _pendingRemoteCandidates.clear();
  }

  /// Local-only: no renegotiation, no track removal. Opponent is told via
  /// the existing mic_toggle message (sent by GameService), not via RTC
  /// renegotiation.
  void setMicEnabled(bool enabled) {
    _micEnabled = enabled;
    for (final track in _localStream?.getAudioTracks() ?? const []) {
      track.enabled = enabled;
    }
    notifyListeners();
  }

  /// Local-only: same as mic — just flips track.enabled. Opponent learns
  /// via camera_toggle message.
  void setCameraEnabled(bool enabled) {
    _cameraEnabled = enabled;
    for (final track in _localStream?.getVideoTracks() ?? const []) {
      track.enabled = enabled;
    }
    notifyListeners();
  }

  /// Reflects the opponent's remote video track enabled/disabled state
  /// locally (e.g. to show an avatar placeholder instead of a frozen frame
  /// when they turn their camera off). Purely cosmetic — flutter_webrtc
  /// already stops rendering frames when the remote track is disabled.
  void setRemoteVideoTrackEnabled(bool enabled) {
    for (final track in _remoteStream?.getVideoTracks() ?? const []) {
      track.enabled = enabled;
    }
    notifyListeners();
  }

  bool _disposed = false;

  /// Tears down the peer connection and all local media. Call this when the
  /// game ends or the opponent disconnects — never on a mic/camera toggle.
  ///
  /// This is async (closing tracks/pc are Futures), so it can't just be a
  /// `dispose()` override — ChangeNotifier.dispose() is synchronous. Call
  /// `await webrtcService.teardown()` from GameService, which internally
  /// calls the real (sync) `dispose()` at the end.
  Future<void> teardown() async {
    if (_disposed) return;

    for (final track in _localStream?.getTracks() ?? const []) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;

    await _remoteStream?.dispose();
    _remoteStream = null;

    await _pc?.close();
    await _pc?.dispose();
    _pc = null;

    _hasVideoTrack = false;
    _micEnabled = true;
    _cameraEnabled = true;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;

    if (_renderersReady) {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      await localRenderer.dispose();
      await remoteRenderer.dispose();
      _renderersReady = false;
    }

    _disposed = true;
    dispose(); // sync ChangeNotifier.dispose(), safe to call now
  }
}
