import 'package:flutter/material.dart';
import '../services/game_service.dart';

class ChatInputBar extends StatefulWidget {
  final GameService game;
  const ChatInputBar({super.key, required this.game});

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final TextEditingController _controller = TextEditingController();

  void _send() {
    final text = _controller.text;
    widget.game.sendChat(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final canChat = widget.game.status == GameStatus.playing;

    return Container(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 8, bottom: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF09090B),
        border: Border(top: BorderSide(color: Color(0xFF27272A))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: canChat,
                maxLength: 200,
                onSubmitted: (_) => _send(),
                style: const TextStyle(fontSize: 13, color: Colors.white),
                decoration: InputDecoration(
                  counterText: '',
                  isDense: true,
                  hintText: canChat ? 'Say something…' : 'Chat unavailable',
                  hintStyle: TextStyle(color: Colors.grey[700], fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF18181B),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(2),
                    borderSide: const BorderSide(color: Color(0xFF27272A)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(2),
                    borderSide: const BorderSide(color: Color(0xFF27272A)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: canChat ? _send : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                disabledBackgroundColor: const Color(0xFF27272A),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(2)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
              child: const Text('SEND',
                  style: TextStyle(fontSize: 11, letterSpacing: 1)),
            ),
          ],
        ),
      ),
    );
  }
}
