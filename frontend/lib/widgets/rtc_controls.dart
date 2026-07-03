import 'package:flutter/material.dart';
import '../services/game_service.dart';

/// A row of icon buttons for voice/video, rendered as an ordinary part of
/// the game session UI — not a separate "call screen". Buttons appear
/// contextually:
///   - "Request voice" / "Request video" show until that permission has
///     been asked for and accepted.
///   - Mic / camera toggles only appear once the corresponding request has
///     been accepted (i.e. tracks actually exist to toggle).
///   - Speaker toggle shows once voice is accepted (audio output routing).
///
/// Follows the same pattern as ChatMessageList/ChatInputBar: takes `game`
/// directly rather than reading it from a Provider, since GameScreen
/// rebuilds this whole subtree via its own addListener/setState.
class RtcControls extends StatelessWidget {
  const RtcControls({super.key, required this.game});

  final GameService game;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    // --- Request buttons (only while not yet accepted) ---
    if (!game.voiceAccepted) {
      children.add(_ActionIcon(
        icon: game.sentVoiceRequest ? Icons.mic_none : Icons.mic,
        label: game.sentVoiceRequest ? 'Requested…' : 'Voice',
        disabled: game.sentVoiceRequest,
        onTap: game.sentVoiceRequest ? null : game.requestVoice,
      ));
    }

    if (!game.videoAccepted) {
      children.add(_ActionIcon(
        icon: game.sentVideoRequest ? Icons.videocam_outlined : Icons.videocam,
        label: game.sentVideoRequest ? 'Requested…' : 'Video',
        disabled: game.sentVideoRequest,
        onTap: game.sentVideoRequest ? null : game.requestVideo,
      ));
    }

    // --- Live toggles (only once accepted / tracks exist) ---
    if (game.voiceAccepted) {
      children.add(_ActionIcon(
        icon: game.micOn ? Icons.mic : Icons.mic_off,
        label: game.micOn ? 'Mute' : 'Unmute',
        highlighted: !game.micOn,
        onTap: game.toggleMic,
      ));

      children.add(_ActionIcon(
        icon: game.speakerOn ? Icons.volume_up : Icons.volume_off,
        label: 'Speaker',
        highlighted: !game.speakerOn,
        onTap: game.toggleSpeaker,
      ));
    }

    if (game.videoAccepted) {
      children.add(_ActionIcon(
        icon: game.cameraOn ? Icons.videocam : Icons.videocam_off,
        label: game.cameraOn ? 'Stop video' : 'Start video',
        highlighted: !game.cameraOn,
        onTap: game.toggleCamera,
      ));
    }

    if (children.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: children
            .map((w) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: w,
                ))
            .toList(),
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.label,
    required this.onTap,
    this.disabled = false,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool disabled;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final color = disabled
        ? Colors.grey
        : highlighted
            ? Colors.redAccent
            : Theme.of(context).colorScheme.primary;

    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: CircleAvatar(
          radius: 20,
          backgroundColor: color.withOpacity(0.15),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}
