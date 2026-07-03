import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/game_service.dart';

/// Renders remote video (large) with local video as a small
/// picture-in-picture overlay in the corner, WhatsApp/FaceTime style.
/// Renders nothing (SizedBox.shrink) until video has been accepted, so it's
/// safe to always mount this widget in game_screen.dart.
class VideoView extends StatelessWidget {
  const VideoView({super.key, required this.game, this.height = 220});

  final GameService game;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (!game.videoAccepted) return const SizedBox.shrink();

    final webrtc = game.webrtcService;

    return SizedBox(
      height: height,
      child: Stack(
        children: [
          // Remote video fills the area.
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                color: Colors.black87,
                child: game.opponentCameraOn
                    ? RTCVideoView(
                        webrtc.remoteRenderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        mirror: false,
                      )
                    : const _CameraOffPlaceholder(label: 'Opponent'),
              ),
            ),
          ),

          // Local video, small PiP overlay bottom-right.
          Positioned(
            right: 8,
            bottom: 8,
            width: height * 0.42,
            height: height * 0.42 * (4 / 3),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24, width: 1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: game.cameraOn
                    ? RTCVideoView(
                        webrtc.localRenderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        mirror: true, // front camera selfie view
                      )
                    : const _CameraOffPlaceholder(label: 'You', small: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraOffPlaceholder extends StatelessWidget {
  const _CameraOffPlaceholder({required this.label, this.small = false});

  final String label;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade900,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off,
              color: Colors.white54, size: small ? 16 : 28),
          if (!small) ...[
            const SizedBox(height: 4),
            Text(
              '$label camera off',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
