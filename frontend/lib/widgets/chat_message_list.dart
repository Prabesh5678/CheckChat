import 'package:flutter/material.dart';
import '../services/game_service.dart';

class ChatMessageList extends StatefulWidget {
  final GameService game;
  final double height;
  const ChatMessageList({super.key, required this.game, this.height = 415});

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CHAT',
            style: TextStyle(
                fontSize: 10, letterSpacing: 2, color: Colors.grey[600])),
        const SizedBox(height: 8),
        Container(
          height: widget.height,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF18181B),
            border: Border.all(color: const Color(0xFF27272A)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: game.messages.isEmpty
              ? Text('No messages yet…',
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]))
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: game.messages.length,
                  itemBuilder: (context, i) {
                    final m = game.messages[i];
                    final isMine = m.from == game.color;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: isMine
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          Text(
                            isMine ? 'YOU' : 'OPPONENT',
                            style: TextStyle(
                                fontSize: 9,
                                letterSpacing: 1,
                                color: Colors.grey[600]),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            constraints: const BoxConstraints(maxWidth: 220),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: isMine
                                  ? Colors.white
                                  : const Color(0xFF27272A),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              m.text,
                              style: TextStyle(
                                fontSize: 12,
                                color: isMine ? Colors.black : Colors.grey[200],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
