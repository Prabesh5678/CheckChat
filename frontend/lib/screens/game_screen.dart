import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:chess/chess.dart' as chess_lib;
import '../services/game_service.dart';
import '../widgets/promotion_dialog.dart';
import '../widgets/chat_message_list.dart';
import '../widgets/chat_input_bar.dart';

const List<String> kFiles = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
const List<String> kRanks = ['8', '7', '6', '5', '4', '3', '2', '1'];

const Map<String, String> kPieceUnicode = {
  'wk': '♔',
  'wq': '♕',
  'wr': '♖',
  'wb': '♗',
  'wn': '♘',
  'wp': '♙',
  'bk': '♚',
  'bq': '♛',
  'br': '♜',
  'bb': '♝',
  'bn': '♞',
  'bp': '♟',
};

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final GameService game;

  @override
  void initState() {
    super.initState();
    game = GameService();
    game.addListener(_onUpdate);
    game.connect();
  }

  void _onUpdate() => setState(() {});

  @override
  void dispose() {
    game.removeListener(_onUpdate);
    game.dispose();
    super.dispose();
  }

  String _statusLabel() {
    switch (game.status) {
      case GameStatus.connecting:
        return 'Connecting…';
      case GameStatus.waiting:
        return 'Waiting for opponent…';
      case GameStatus.error:
        return 'Connection error';
      case GameStatus.disconnected:
        return 'Disconnected';
      case GameStatus.gameOver:
        return _gameOverLabel();
      case GameStatus.playing:
        if (game.promotionPending) return 'Choose promotion piece';
        return game.myTurn ? '▶ Your turn' : "Opponent's turn";
    }
  }

  String _gameOverLabel() {
    if (game.gameOverReason == 'opponent_disconnected') {
      return 'Opponent left — You win!';
    }
    if (game.winner == 'draw') {
      const reasons = {
        'stalemate': 'Draw — Stalemate',
        'insufficient_material': 'Draw — Insufficient Material',
        'threefold_repetition': 'Draw — Threefold Repetition',
        '50_move_rule': 'Draw — 50 Move Rule',
      };
      return reasons[game.gameOverReason] ?? 'Draw';
    }
    return game.winner == game.color ? 'You won!' : 'You lost';
  }

  Color _statusColor() {
    if (game.status == GameStatus.playing) {
      return game.myTurn ? Colors.white : Colors.grey[500]!;
    }
    if (game.status == GameStatus.gameOver) {
      if (game.gameOverReason == 'opponent_disconnected' ||
          game.winner == game.color) {
        return Colors.green[400]!;
      }
      if (game.winner == 'draw') return Colors.yellow[400]!;
      return Colors.red[400]!;
    }
    if (game.status == GameStatus.error ||
        game.status == GameStatus.disconnected) {
      return Colors.red[400]!;
    }
    return Colors.grey[400]!;
  }

  List<String> get _displayRanks =>
      game.color == 'black' ? kRanks.reversed.toList() : kRanks;
  List<String> get _displayFiles =>
      game.color == 'black' ? kFiles.reversed.toList() : kFiles;

  // convert chess package's Piece to our key format e.g. "wK", "bP"
  String? _pieceAt(String sq) {
    final p = game.board.get(sq);
    if (p == null) return null;
    // chess package Color enum: compare directly, never use toString()
    final colorChar = (p.color == chess_lib.Color.WHITE) ? 'w' : 'b';
    final typeChar = _typeChar(p.type);
    return colorChar + typeChar;
  }

  String _typeChar(chess_lib.PieceType t) {
    if (t == chess_lib.PieceType.KING) return 'k';
    if (t == chess_lib.PieceType.QUEEN) return 'q';
    if (t == chess_lib.PieceType.ROOK) return 'r';
    if (t == chess_lib.PieceType.BISHOP) return 'b';
    if (t == chess_lib.PieceType.KNIGHT) return 'n';
    return 'p'; // PAWN
  }

  @override
  Widget build(BuildContext context) {
    final showBoard = game.status != GameStatus.connecting &&
        game.status != GameStatus.waiting;
    final showChat =
        game.status == GameStatus.playing || game.status == GameStatus.gameOver;

    return Scaffold(
      // input bar pinned to bottom — never needs scrolling to reach, auto-lifts above keyboard
      resizeToAvoidBottomInset: true,
      bottomNavigationBar: showChat ? ChatInputBar(game: game) : null,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: MediaQuery.of(context).size.width < 500 ? 12 : 24,
              vertical: 24,
            ),
            child: Column(
              children: [
                // status bar
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('♟', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: 8),
                    Text(
                      _statusLabel().toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 2,
                        color: _statusColor(),
                      ),
                    ),
                    if (game.color != null &&
                        game.status != GameStatus.connecting) ...[
                      const SizedBox(width: 8),
                      Text('· ${game.color}',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[700])),
                    ],
                    // CHECK warning badge
                    if (game.inCheck && game.status == GameStatus.playing) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE53935),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const Text(
                          'CHECK',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 24),

                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.start,
                  spacing: 24,
                  runSpacing: 24,
                  children: [
                    // board
                    Stack(
                      children: [
                        if (!showBoard)
                          Builder(builder: (context) {
                            final w = MediaQuery.of(context).size.width < 500
                                ? MediaQuery.of(context).size.width - 24
                                : 400.0;
                            final size = w.clamp(220.0, 400.0);
                            return Container(
                              width: size,
                              height: size,
                              decoration: BoxDecoration(
                                color: const Color(0xFF18181B),
                                border:
                                    Border.all(color: const Color(0xFF27272A)),
                              ),
                              child: Center(
                                child: Text(
                                  _statusLabel().toUpperCase(),
                                  style: TextStyle(
                                      fontSize: 13,
                                      letterSpacing: 2,
                                      color: Colors.grey[600]),
                                ),
                              ),
                            );
                          })
                        else
                          _buildBoard(),
                        if (game.promotionPending)
                          PromotionOverlay(
                              color: game.color,
                              onChoose: game.choosePromotion),
                      ],
                    ),

                    // chat message list — scrollable inline, no input here
                    if (showChat)
                      SizedBox(
                        width: MediaQuery.of(context).size.width < 500
                            ? MediaQuery.of(context).size.width - 24
                            : 260,
                        child: ChatMessageList(
                          game: game,
                          height: MediaQuery.of(context).size.width < 500
                              ? 200
                              : 415,
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 24),

                // game over actions
                if (game.status == GameStatus.gameOver)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: game.playAgain,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(0)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                        ),
                        child: const Text('PLAY AGAIN',
                            style: TextStyle(fontSize: 11, letterSpacing: 2)),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () =>
                            Navigator.pushReplacementNamed(context, '/'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.grey[400],
                          side: BorderSide(color: Colors.grey[700]!),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(0)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                        ),
                        child: const Text('HOME',
                            style: TextStyle(fontSize: 11, letterSpacing: 2)),
                      ),
                    ],
                  ),

                if (game.status == GameStatus.disconnected ||
                    game.status == GameStatus.error)
                  OutlinedButton(
                    onPressed: () =>
                        Navigator.pushReplacementNamed(context, '/'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey[400],
                      side: BorderSide(color: Colors.grey[700]!),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(0)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                    ),
                    child: const Text('BACK TO HOME',
                        style: TextStyle(fontSize: 11, letterSpacing: 2)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBoard() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // reserve space for rank labels (≈18) and side padding already applied by parent
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width -
                48; // fallback: screen minus padding
        final usable = (availableWidth - 18).clamp(200.0, 400.0);
        final squareSize = (usable / 8).floorToDouble();

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // rank labels
            Column(
              children: _displayRanks
                  .map((r) => SizedBox(
                        height: squareSize,
                        width: 16,
                        child: Center(
                          child: Text(r,
                              style: TextStyle(
                                  fontSize: 10, color: Colors.grey[600])),
                        ),
                      ))
                  .toList(),
            ),

            Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFF3F3F46))),
                  child: Column(
                    children: _displayRanks.map((rank) {
                      return Row(
                        children: _displayFiles.map((file) {
                          final sq = file + rank;
                          return _buildSquare(file, rank, sq, squareSize);
                        }).toList(),
                      );
                    }).toList(),
                  ),
                ),
                // file labels
                Row(
                  children: _displayFiles
                      .map((f) => SizedBox(
                            width: squareSize,
                            child: Center(
                              child: Text(f,
                                  style: TextStyle(
                                      fontSize: 10, color: Colors.grey[600])),
                            ),
                          ))
                      .toList(),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildSquare(String file, String rank, String sq, double squareSize) {
    final piece = _pieceAt(sq);
    final isLight = (kFiles.indexOf(file) + kRanks.indexOf(rank)) % 2 == 0;
    final isSelected = game.selected == sq;
    final isLegal = game.legalSquares.contains(sq);
    final isLastMove = sq == game.lastMoveFrom || sq == game.lastMoveTo;

    Color bgColor = isLight ? const Color(0xFFC8B89A) : const Color(0xFF8B6C4A);
    if (isSelected) {
      bgColor = const Color(0xFFF0D060);
    } else if (isLegal)
      bgColor = isLight ? const Color(0xFFA8D8A0) : const Color(0xFF5A9E52);
    else if (sq == game.kingInCheckSquare)
      bgColor = const Color(0xFFE53935); // red — king in check
    else if (isLastMove)
      bgColor = isLight ? const Color(0xFFF6EB7A) : const Color(0xFFBBA53C);

    final pieceFontSize = squareSize * 0.64;
    final dotSize = squareSize * 0.24;

    // square visual — clipped so pieces never bleed into adjacent squares
    Widget squareContent = SizedBox(
      width: squareSize,
      height: squareSize,
      child: ClipRect(
        child: ColoredBox(
          color: bgColor,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.hardEdge,
            children: [
              if (isLegal && piece == null)
                Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: BoxDecoration(
                    color: Colors.green[800]!.withValues(alpha: 0.7),
                    shape: BoxShape.circle,
                  ),
                ),
              if (piece != null)
                Text(
                  kPieceUnicode[piece] ?? '',
                  style: TextStyle(
                    fontSize: pieceFontSize,
                    height: 1,
                    color: piece.startsWith('w')
                        ? Colors.white
                        : const Color(0xFF1C1917),
                    shadows: [
                      Shadow(
                        color: piece.startsWith('w')
                            ? Colors.black54
                            : Colors.white38,
                        blurRadius: 3,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    // ── MOBILE: pure tap, zero drag widgets ──
    if (!kIsWeb) {
      return GestureDetector(
        onTap: () => game.selectSquare(sq),
        child: squareContent,
      );
    }

    // ── WEB: tap + drag ──
    Widget webSquare = DragTarget<String>(
      onWillAcceptWithDetails: (d) => game.legalSquares.contains(sq),
      onAcceptWithDetails: (d) => game.attemptMove(d.data, sq),
      builder: (context, _, __) => GestureDetector(
        onTap: () => game.selectSquare(sq),
        child: squareContent,
      ),
    );

    if (piece != null && game.canDrag(sq)) {
      return LongPressDraggable<String>(
        data: sq,
        delay: const Duration(milliseconds: 120),
        feedback: Material(
          color: Colors.transparent,
          child: Text(
            kPieceUnicode[piece] ?? '',
            style: TextStyle(
              fontSize: pieceFontSize * 1.2,
              color: piece.startsWith('w')
                  ? Colors.white
                  : const Color(0xFF1C1917),
              shadows: const [Shadow(color: Colors.black45, blurRadius: 6)],
            ),
          ),
        ),
        childWhenDragging: SizedBox(
          width: squareSize,
          height: squareSize,
          child: ColoredBox(color: bgColor.withValues(alpha: 0.5)),
        ),
        onDragStarted: () => game.selectSquare(sq),
        onDraggableCanceled: (_, __) {
          game.selectSquare(sq);
        },
        child: webSquare,
      );
    }

    return webSquare;
  }
}
