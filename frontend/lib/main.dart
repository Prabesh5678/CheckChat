import 'package:flutter/material.dart';
import 'screens/landing_screen.dart';
import 'screens/game_screen.dart';

void main() {
  runApp(const ChessApp());
}

class ChessApp extends StatelessWidget {
  const ChessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF09090B), // zinc-950
        colorScheme: const ColorScheme.dark(
          surface: Color(0xFF09090B),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const LandingScreen(),
        '/game': (context) => const GameScreen(),
      },
    );
  }
}
