import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'game_service.dart' show wsUrl;

/// Talks to the backend's payment REST endpoints (mounted on the same
/// Express app that now shares a port with the existing WebSocket server —
/// see backend/server.js).
///
/// Identity note: this app has no login/accounts system, so there's no
/// real "user" to attach a coin balance to. `deviceId` is a random ID
/// generated once and persisted locally via SharedPreferences — it
/// identifies *this app install*, not a person. That's fine for learning
/// the payment flow itself, but it means: reinstalling the app, or using
/// the app on a second device, starts a fresh balance. A real product
/// would replace this with an actual account system and use the logged-in
/// user's ID instead.
class PaymentService {
  static const _deviceIdPrefsKey = 'payment_device_id';

  String? _deviceId;

  /// Must be called once (e.g. in CoinStoreScreen.initState) before any
  /// other method on this class.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdPrefsKey);
    if (existing != null) {
      _deviceId = existing;
      return;
    }
    final generated = _generateId();
    await prefs.setString(_deviceIdPrefsKey, generated);
    _deviceId = generated;
  }

  String get deviceId {
    final id = _deviceId;
    if (id == null) {
      throw StateError('PaymentService.init() must be called before use');
    }
    return id;
  }

  String _generateId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The payment REST endpoints live on the same host/port as the game
  /// WebSocket server (see backend/server.js) — this just swaps the
  /// ws(s):// scheme from wsUrl for http(s)://.
  String get _restBaseUrl {
    final uri = Uri.parse(wsUrl);
    final scheme = uri.scheme == 'wss' ? 'https' : 'http';
    return uri.replace(scheme: scheme).toString();
  }

  Future<int> fetchBalance() async {
    final response = await http.get(
      Uri.parse('$_restBaseUrl/api/payments/balance/$deviceId'),
    );
    if (response.statusCode != 200) {
      throw Exception('fetchBalance failed: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['balance'] as int;
  }

  /// Kicks off a purchase for [packageId] via [gateway] ('stripe' for now;
  /// 'khalti'/'esewa' will return a 501 until those routes are built).
  /// Returns the URL the app should open (browser/webview) for the user to
  /// complete payment on the gateway's hosted page.
  Future<String> initiatePurchase({
    required String gateway,
    required String packageId,
  }) async {
    final response = await http.post(
      Uri.parse('$_restBaseUrl/api/payments/initiate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'gateway': gateway,
        'packageId': packageId,
        'deviceId': deviceId,
      }),
    );

    if (response.statusCode != 200) {
      debugPrint('[Payments] initiate failed: ${response.statusCode} '
          '${response.body}');
      throw Exception('Could not start $gateway checkout '
          '(${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['redirectUrl'] as String;
  }
}

/// The three coin packages, mirrored from backend/store/orderStore.js —
/// kept as a single source of truth there; this is just the display copy
/// for the Flutter UI (price is shown to the user, but the backend is what
/// actually determines the real charge amount — never trust a client-sent
/// price).
const List<CoinPackage> kCoinPackages = [
  CoinPackage(id: 'small', coins: 100, priceLabel: 'Rs. 10'),
  CoinPackage(id: 'medium', coins: 500, priceLabel: 'Rs. 40'),
  CoinPackage(id: 'large', coins: 1000, priceLabel: 'Rs. 70'),
];

class CoinPackage {
  const CoinPackage({
    required this.id,
    required this.coins,
    required this.priceLabel,
  });

  final String id;
  final int coins;
  final String priceLabel;
}
