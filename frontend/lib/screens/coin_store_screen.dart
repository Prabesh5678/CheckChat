import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/payment_service.dart';

/// A simple coin store screen: shows the current balance and lets the
/// person buy coin packages through Stripe (Khalti/eSewa buttons are shown
/// but disabled until those backend routes exist — see routes/payments.js).
///
/// Because there's no deep-link plumbing here (see the class-level note in
/// payment_service.dart), this screen relies on WidgetsBindingObserver to
/// notice when the app resumes — i.e. the person switches back from the
/// browser/webview after paying — and re-fetches the balance then. It's
/// not instant/pushed, but it's simple and works identically on web and
/// mobile without any custom URL scheme setup.
class CoinStoreScreen extends StatefulWidget {
  const CoinStoreScreen({super.key});

  @override
  State<CoinStoreScreen> createState() => _CoinStoreScreenState();
}

class _CoinStoreScreenState extends State<CoinStoreScreen>
    with WidgetsBindingObserver {
  final PaymentService _payments = PaymentService();

  int? _balance;
  bool _loading = true;
  String? _error;
  String? _purchasingPackageId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _payments.init();
      await _refreshBalance();
    } catch (e) {
      setState(() {
        _error = 'Could not load payment service: $e';
        _loading = false;
      });
    }
  }

  Future<void> _refreshBalance() async {
    try {
      final balance = await _payments.fetchBalance();
      if (!mounted) return;
      setState(() {
        _balance = balance;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not fetch balance: $e';
        _loading = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The person switching back to the app after completing (or
    // abandoning) checkout in the browser/webview is our only signal that
    // something might have changed — refresh the balance then.
    if (state == AppLifecycleState.resumed) {
      _refreshBalance();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _buy(CoinPackage package, String gateway) async {
    setState(() => _purchasingPackageId = package.id);
    try {
      final redirectUrl = await _payments.initiatePurchase(
        gateway: gateway,
        packageId: package.id,
      );
      final uri = Uri.parse(redirectUrl);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _showError('Could not open checkout page.');
      }
    } catch (e) {
      if (mounted) _showError('$e');
    } finally {
      if (mounted) setState(() => _purchasingPackageId = null);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Coin Store'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refreshBalance,
            tooltip: 'Refresh balance',
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed: _bootstrap,
                            child: const Text('RETRY'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _BalanceCard(balance: _balance ?? 0),
                      const SizedBox(height: 24),
                      const Text(
                        'BUY COINS',
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 2,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final package in kCoinPackages)
                        _PackageCard(
                          package: package,
                          isPurchasing: _purchasingPackageId == package.id,
                          onBuyKhalti: () => _buy(package, 'khalti'),
                          onBuyEsewa: () => _buy(package, 'esewa'),
                        ),
                    ],
                  ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF18181B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.monetization_on, color: Color(0xFFF0D060), size: 32),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$balance',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Text(
                'coins',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PackageCard extends StatelessWidget {
  const _PackageCard({
    required this.package,
    required this.isPurchasing,
    required this.onBuyKhalti,
    required this.onBuyEsewa,
  });

  final CoinPackage package;
  final bool isPurchasing;
  final VoidCallback onBuyKhalti;
  final VoidCallback onBuyEsewa;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: const Color(0xFF18181B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF27272A)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${package.coins} coins',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                Text(
                  package.priceLabel,
                  style: TextStyle(color: Colors.grey[400]),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isPurchasing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: onBuyKhalti,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5C2D91), // Khalti purple
                    ),
                    child: const Text('Khalti'),
                  ),
                  ElevatedButton(
                    onPressed: onBuyEsewa,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF60BB46), // eSewa green
                    ),
                    child: const Text('eSewa'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
