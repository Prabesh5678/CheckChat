import 'package:flutter/material.dart';

class PromotionPieces {
  static const List<Map<String, String>> pieces = [
    {'key': 'q', 'label': 'Queen', 'white': '♕', 'black': '♛'},
    {'key': 'r', 'label': 'Rook', 'white': '♖', 'black': '♜'},
    {'key': 'b', 'label': 'Bishop', 'white': '♗', 'black': '♝'},
    {'key': 'n', 'label': 'Knight', 'white': '♘', 'black': '♞'},
  ];
}

class PromotionOverlay extends StatelessWidget {
  final String? color; // "white" | "black" — whose pawn is promoting
  final void Function(String pieceKey) onChoose;

  const PromotionOverlay(
      {super.key, required this.color, required this.onChoose});

  @override
  Widget build(BuildContext context) {
    final isWhite = color == 'white';

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.7),
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF18181B), // zinc-900
              border: Border.all(color: const Color(0xFF3F3F46)), // zinc-700
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PROMOTE PAWN TO',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 2,
                    color: Colors.grey[500],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: PromotionPieces.pieces.map((p) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: GestureDetector(
                        onTap: () => onChoose(p['key']!),
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: const Color(0xFF27272A), // zinc-800
                            border: Border.all(color: const Color(0xFF52525B)),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                isWhite ? p['white']! : p['black']!,
                                style: TextStyle(
                                  fontSize: 28,
                                  color: isWhite
                                      ? Colors.white
                                      : const Color(0xFF1C1917),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                p['label']!.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 8,
                                  letterSpacing: 1,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
