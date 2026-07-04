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
///
/// Every step of the offer/answer/ICE/media lifecycle logs through [_log],
/// tagged with platform (web / android / ios / etc) so you can grep two
/// devices' console output side by side and see exactly where the two
/// sides' logs diverge — that divergence point is where the connection is
/// actually breaking.
class WebRTCService extends ChangeNotifier {
  WebRTCService({required this.sendMessage}) {
    _log('WebRTCService created');
  }

  /// Sends a signaling message over the existing game WebSocket.
  /// Signature matches GameService's internal `_send(type, data)` helper.
  final void Function(String type, Map<String, dynamic> data) sendMessage;

  static String get _platformTag =>
      kIsWeb ? 'web' : defaultTargetPlatform.toString().split('.').last;

  void _log(String message) {
    debugPrint('[RTC][WebRTCService][$_platformTag] $message');
  }

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  bool _hasVideoTrack = false;
  bool _micEnabled = true;
  bool _cameraEnabled = true;
  bool _speakerEnabled = true;

  // ICE candidates that arrive before we have a remote description yet
  // (e.g. opponent's candidates trickling in before our answer is set).
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  bool _remoteDescriptionSet = false;

  bool get hasPeerConnection => _pc != null;
  bool get hasVideoTrack => _hasVideoTrack;
  bool get micEnabled => _micEnabled;
  bool get cameraEnabled => _cameraEnabled;
  bool get speakerEnabled => _speakerEnabled;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  static const Map<String, dynamic> _iceServersConfig = {
    'iceServers': [
      {
        'urls': ['stun:stun.l.google.com:19302'],
      },
      // Free TURN server for TESTING ONLY (openrelay.metered.ca) — this is
      // rate-limited and not meant for production traffic, but it's enough
      // to confirm whether missing TURN is why connections are flaky for
      // you. Swap for your own coturn deployment or a paid provider
      // (Twilio, Metered, Xirsys) before shipping.
      {
        'urls': [
          'turn:openrelay.metered.ca:80',
          'turn:openrelay.metered.ca:443',
          'turn:openrelay.metered.ca:443?transport=tcp',
        ],
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  };

  Future<void> _ensureRenderers() async {
    if (_renderersReady) {
      _log('renderers already initialized, skipping');
      return;
    }
    _log('initializing local + remote renderers…');
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
    _log('renderers initialized');
  }

  Future<void> _ensurePeerConnection() async {
    if (_pc != null) {
      _log('peer connection already exists, reusing');
      return;
    }

    _log('creating RTCPeerConnection…');
    _pc = await createPeerConnection(_iceServersConfig);
    _log('RTCPeerConnection created');

    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null) {
        _log('onIceCandidate: end-of-candidates signal (null candidate)');
        return;
      }
      _log(
        'onIceCandidate: generated local candidate '
        '(mid=${candidate.sdpMid}, mLineIndex=${candidate.sdpMLineIndex}) '
        '— sending rtc_ice',
      );
      sendMessage('rtc_ice', {
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    _pc!.onTrack = (RTCTrackEvent event) {
      _log(
        'onTrack: received remote track kind=${event.track.kind}, '
        'streams=${event.streams.length}',
      );
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        remoteRenderer.srcObject = _remoteStream;
        _applySpeakerState();
        notifyListeners();
      }
    };

    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      // Surface state changes so UI (e.g. a "connecting…" indicator) can
      // react if desired. We deliberately do NOT auto-dispose here on
      // failure/disconnected — GameService decides lifecycle based on the
      // actual game/opponent-connection state, not transient ICE hiccups.
      _log('onConnectionState: $state');
      notifyListeners();
    };

    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      // If this reaches RTCIceConnectionStateFailed with no TURN server
      // configured, that's the signature of a NAT-traversal failure —
      // check here first when connections are intermittent.
      _log('onIceConnectionState: $state');
      notifyListeners();
    };

    _pc!.onIceGatheringState = (RTCIceGatheringState state) {
      _log('onIceGatheringState: $state');
    };

    _pc!.onSignalingState = (RTCSignalingState state) {
      _log('onSignalingState: $state');
    };

    _pc!.onRenegotiationNeeded = () {
      _log('onRenegotiationNeeded fired');
    };
  }

  /// Grabs local mic (+ camera if [withVideo]) and publishes tracks onto the
  /// single shared peer connection. Safe to call twice: the second call with
  /// withVideo=true after an audio-only call will just add the video track
  /// on top of the existing audio track (upgrade path), it will not recreate
  /// the audio track or the connection.
  Future<void> startLocalMedia({required bool withVideo}) async {
    _log('startLocalMedia(withVideo: $withVideo) called');
    await _ensureRenderers();
    await _ensurePeerConnection();

    final bool needsAudio = _localStream == null;
    final bool needsVideo = withVideo && !_hasVideoTrack;
    _log('needsAudio=$needsAudio, needsVideo=$needsVideo, '
        'hasVideoTrack=$_hasVideoTrack');

    if (!needsAudio && !needsVideo) {
      _log('nothing new to publish, returning early');
      return;
    }

    if (_localStream == null) {
      // First time: grab audio (always) + video (if requested up front).
      _log('calling getUserMedia (audio: true, video: $withVideo)…');
      final MediaStream stream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': withVideo
              ? {
                  'facingMode': 'user',
                  'width': {'ideal': 640},
                  'height': {'ideal': 480},
                }
              : false,
        });
      } catch (e, st) {
        _log('getUserMedia FAILED: $e');
        _log('getUserMedia stack: $st');
        rethrow;
      }
      _log('getUserMedia succeeded: '
          '${stream.getAudioTracks().length} audio track(s), '
          '${stream.getVideoTracks().length} video track(s)');

      _localStream = stream;
      localRenderer.srcObject = stream;

      for (final track in stream.getTracks()) {
        _log('addTrack: publishing ${track.kind} track to peer connection');
        await _pc!.addTrack(track, stream);
      }
      _hasVideoTrack = withVideo && stream.getVideoTracks().isNotEmpty;
      _log('initial local media published, hasVideoTrack=$_hasVideoTrack');
    } else if (needsVideo) {
      // Upgrade path: voice was already active, now add video on top of the
      // existing stream/connection. This is the one case that requires
      // renegotiation — handled by the caller re-running the offer flow
      // after this returns (see GameService's video-accepted handler).
      _log('upgrade path: calling getUserMedia (video only)…');
      final MediaStream videoStream;
      try {
        videoStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'facingMode': 'user',
            'width': {'ideal': 640},
            'height': {'ideal': 480},
          },
        });
      } catch (e, st) {
        _log('upgrade getUserMedia FAILED: $e');
        _log('upgrade getUserMedia stack: $st');
        rethrow;
      }
      final videoTrack = videoStream.getVideoTracks().first;
      _localStream!.addTrack(videoTrack);
      localRenderer.srcObject = _localStream;
      _log('addTrack: publishing upgraded video track to peer connection');
      await _pc!.addTrack(videoTrack, _localStream!);
      _hasVideoTrack = true;
      _log('video upgrade complete, caller should renegotiate now');
    }

    notifyListeners();
  }

  /// Called by the peer whose request (voice or video) was just accepted.
  /// That peer becomes the offerer for this negotiation round.
  Future<void> createAndSendOffer() async {
    _log('createAndSendOffer() called');
    await _ensurePeerConnection();

    // Critical: this may be a RENEGOTIATION (e.g. voice already connected,
    // now upgrading to video). The old remote description is stale for the
    // new m-line being added, so any ICE candidates the answerer trickles
    // in for this round must be queued again until the fresh answer sets a
    // remote description that actually contains that new m-line. Without
    // this reset, addCandidate() can be called against a mismatched remote
    // description and fail — intermittently, depending on whether the
    // candidate or the answer arrives first.
    _remoteDescriptionSet = false;
    _log('reset _remoteDescriptionSet=false for this negotiation round');

    final offer = await _pc!.createOffer();
    _log('offer created (type=${offer.type}, sdp length=${offer.sdp?.length})');
    await _pc!.setLocalDescription(offer);
    _log('local description (offer) set — sending rtc_offer');
    sendMessage('rtc_offer', {
      'sdp': {'sdp': offer.sdp, 'type': offer.type},
    });
  }

  /// Handles an incoming offer (we are the answerer for this round).
  Future<void> handleRemoteOffer(Map<String, dynamic> sdpMap) async {
    _log('handleRemoteOffer() called');
    await _ensurePeerConnection();
    final desc = RTCSessionDescription(sdpMap['sdp'], sdpMap['type']);
    await _pc!.setRemoteDescription(desc);
    _remoteDescriptionSet = true;
    _log('remote description (offer) set');
    await _drainPendingCandidates();

    final answer = await _pc!.createAnswer();
    _log(
      'answer created (type=${answer.type}, sdp length=${answer.sdp?.length})',
    );
    await _pc!.setLocalDescription(answer);
    _log('local description (answer) set — sending rtc_answer');
    sendMessage('rtc_answer', {
      'sdp': {'sdp': answer.sdp, 'type': answer.type},
    });
  }

  /// Handles an incoming answer (we are the offerer for this round).
  Future<void> handleRemoteAnswer(Map<String, dynamic> sdpMap) async {
    _log('handleRemoteAnswer() called');
    if (_pc == null) {
      _log('WARNING: handleRemoteAnswer called with no peer connection — '
          'ignoring (did teardown() run before this arrived?)');
      return;
    }
    final desc = RTCSessionDescription(sdpMap['sdp'], sdpMap['type']);
    await _pc!.setRemoteDescription(desc);
    _remoteDescriptionSet = true;
    _log('remote description (answer) set');
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
      _log(
        'handleRemoteIceCandidate: no remote description yet '
        '(pc null=${_pc == null}) — queuing '
        '(queue size now ${_pendingRemoteCandidates.length + 1})',
      );
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    _log('handleRemoteIceCandidate: applying candidate immediately '
        '(mid=${candidate.sdpMid})');
    try {
      await _pc!.addCandidate(candidate);
    } catch (e) {
      _log('addCandidate FAILED: $e');
      rethrow;
    }
  }

  Future<void> _drainPendingCandidates() async {
    if (_pc == null) return;
    if (_pendingRemoteCandidates.isEmpty) {
      _log('_drainPendingCandidates: nothing queued');
      return;
    }
    _log(
      '_drainPendingCandidates: applying ${_pendingRemoteCandidates.length} '
      'queued candidate(s)',
    );
    for (final c in _pendingRemoteCandidates) {
      try {
        await _pc!.addCandidate(c);
      } catch (e) {
        _log('addCandidate (drained) FAILED: $e');
      }
    }
    _pendingRemoteCandidates.clear();
    _log('_drainPendingCandidates: queue cleared');
  }

  /// Local-only: no renegotiation, no track removal. Opponent is told via
  /// the existing mic_toggle message (sent by GameService), not via RTC
  /// renegotiation.
  void setMicEnabled(bool enabled) {
    _log('setMicEnabled($enabled)');
    _micEnabled = enabled;
    for (final track in _localStream?.getAudioTracks() ?? const []) {
      track.enabled = enabled;
    }
    notifyListeners();
  }

  /// Local-only: same as mic — just flips track.enabled. Opponent learns
  /// via camera_toggle message.
  void setCameraEnabled(bool enabled) {
    _log('setCameraEnabled($enabled)');
    _cameraEnabled = enabled;
    for (final track in _localStream?.getVideoTracks() ?? const []) {
      track.enabled = enabled;
    }
    notifyListeners();
  }

  /// Local-only: mute/unmute the received audio track without affecting the
  /// remote peer. Note this is a "deafen" toggle (disables the incoming
  /// audio track locally) rather than a hardware earpiece/speaker route
  /// switch — if you want an actual output-device switch, that's
  /// `Helper.setSpeakerphoneOn()` from flutter_webrtc instead, called from
  /// GameService.toggleSpeaker().
  void setSpeakerEnabled(bool enabled) {
    _log('setSpeakerEnabled($enabled)');
    _speakerEnabled = enabled;
    _applySpeakerState();
    notifyListeners();
  }

  void _applySpeakerState() {
    for (final track in _remoteStream?.getAudioTracks() ?? const []) {
      track.enabled = _speakerEnabled;
    }
  }

  /// Reflects the opponent's remote video track enabled/disabled state
  /// locally (e.g. to show an avatar placeholder instead of a frozen frame
  /// when they turn their camera off). Purely cosmetic — flutter_webrtc
  /// already stops rendering frames when the remote track is disabled.
  void setRemoteVideoTrackEnabled(bool enabled) {
    _log('setRemoteVideoTrackEnabled($enabled)');
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
    if (_disposed) {
      _log('teardown() called but already disposed — no-op');
      return;
    }
    _log('teardown() starting…');

    for (final track in _localStream?.getTracks() ?? const []) {
      _log('stopping local ${track.kind} track');
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;

    await _remoteStream?.dispose();
    _remoteStream = null;

    await _pc?.close();
    await _pc?.dispose();
    _pc = null;
    _log('peer connection closed and disposed');

    _hasVideoTrack = false;
    _micEnabled = true;
    _cameraEnabled = true;
    _speakerEnabled = true;
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;

    if (_renderersReady) {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      await localRenderer.dispose();
      await remoteRenderer.dispose();
      _renderersReady = false;
      _log('renderers disposed');
    }

    _disposed = true;
    _log('teardown() complete');
    dispose(); // sync ChangeNotifier.dispose(), safe to call now
  }
}
