import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../services/ble_service.dart';

class ConnectDeviceScreen extends StatefulWidget {
  const ConnectDeviceScreen({super.key});

  @override
  State<ConnectDeviceScreen> createState() => _ConnectDeviceScreenState();
}

class _ConnectDeviceScreenState extends State<ConnectDeviceScreen> {
  final BleService _ble = BleService.instance;
  bool _connecting = false;

  Future<void> _handleConnect() async {
    if (_connecting) return;
    setState(() => _connecting = true);
    final ok = await _ble.connect();
    if (!mounted) return;
    setState(() => _connecting = false);
    if (ok) {
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      // US1: failed connection shows an error message with retry
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_ble.lastError.value ?? 'Connection failed'),
          backgroundColor: const Color(0xFF2A1A1A),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Retry',
            textColor: AppTheme.neonGreen,
            onPressed: _handleConnect,
          ),
        ),
      );
    }
  }

  String _statusLabel(BleConnectionState state) {
    switch (state) {
      case BleConnectionState.scanning:
        return 'Scanning...';
      case BleConnectionState.connecting:
        return 'Connecting...';
      case BleConnectionState.connected:
        return 'Connected';
      case BleConnectionState.error:
        return 'Connection failed';
      case BleConnectionState.disconnected:
        return 'Disconnected';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [
              AppTheme.darkBg,
              AppTheme.darkBg,
              const Color(0xFF0A1510),
            ],
          ),
        ),
        child: SafeArea(
          // Scrollable + min-height so the Spacers still center the device on
          // tall screens but the layout scrolls (no overflow) on short ones.
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
              // Header
              Padding(
                padding: EdgeInsets.all(Responsive.w(context, 16)),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      color: AppTheme.textPrimary,
                    ),
                    const Spacer(),
                    const Text(
                      'Connect Device',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    SizedBox(width: Responsive.w(context, 48)),
                  ],
                ),
              ),
              SizedBox(height: Responsive.h(context, 8)),
              Image.asset(
                'assets/logo.png',
                width: Responsive.w(context, 220),
                fit: BoxFit.contain,
              ),
              const Spacer(),
              // Device visualization
              Stack(
                alignment: Alignment.center,
                children: [
                  // Glow effect
                  Container(
                    width: Responsive.r(context, 200),
                    height: Responsive.r(context, 200),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.neonGreen.withValues(alpha:0.15),
                          blurRadius: Responsive.r(context, 60),
                          spreadRadius: Responsive.r(context, 20),
                        ),
                      ],
                    ),
                  ),
                  // Smart Tracker device
                  Column(
                    children: [
                      Container(
                        width: Responsive.r(context, 140),
                        height: Responsive.r(context, 140),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF1A1A1A),
                          border: Border.all(
                            color: AppTheme.neonGreen.withValues(alpha:0.6),
                            width: Responsive.r(context, 3),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.neonGreen.withValues(alpha:0.3),
                              blurRadius: Responsive.r(context, 30),
                            ),
                          ],
                        ),
                        child: Center(
                          child: ShaderMask(
                            blendMode: BlendMode.srcIn,
                            shaderCallback: (bounds) => LinearGradient(
                              colors: [
                                AppTheme.neonGreen,
                                AppTheme.neonGreenDim,
                              ],
                            ).createShader(bounds),
                            child: const Text(
                              '9',
                              style: TextStyle(
                                fontSize: 56,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: Responsive.h(context, 16)),
                      Icon(
                        Icons.bluetooth_rounded,
                        size: Responsive.r(context, 32),
                        color: AppTheme.neonGreen.withValues(alpha:0.8),
                      ),
                    ],
                  ),
                ],
              ),
              const Spacer(),
              // Device info card
              Padding(
                padding: EdgeInsets.symmetric(horizontal: Responsive.w(context, 24)),
                child: Container(
                  padding: EdgeInsets.all(Responsive.w(context, 20)),
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: BorderRadius.circular(Responsive.r(context, 16)),
                    border: Border.all(
                      color: AppTheme.cardBgLight,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: Responsive.r(context, 48),
                        height: Responsive.r(context, 48),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.cardBgLight,
                          border: Border.all(
                            color: AppTheme.neonGreen.withValues(alpha:0.5),
                          ),
                        ),
                        child: const Center(
                          child: Text(
                            '9',
                            style: TextStyle(
                              color: AppTheme.neonGreen,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: Responsive.w(context, 16)),
                      Expanded(
                        child: ValueListenableBuilder<BleConnectionState>(
                          valueListenable: _ble.connectionState,
                          builder: (context, state, _) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Smart Tracker',
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  _statusLabel(state),
                                  style: TextStyle(
                                    color: AppTheme.textSecondary.withValues(alpha:0.8),
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      Icon(
                        Icons.signal_cellular_alt_rounded,
                        color: AppTheme.neonGreen,
                        size: Responsive.r(context, 24),
                      ),
                    ],
                  ),
                ),
              ),
              // Error message (US1)
              ValueListenableBuilder<String?>(
                valueListenable: _ble.lastError,
                builder: (context, err, _) {
                  if (err == null || _connecting) return const SizedBox.shrink();
                  return Padding(
                    padding: EdgeInsets.only(
                      top: Responsive.h(context, 12),
                      left: Responsive.w(context, 24),
                      right: Responsive.w(context, 24),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: Color(0xFFFF6B6B), size: 18),
                        SizedBox(width: Responsive.w(context, 8)),
                        Flexible(
                          child: Text(
                            err,
                            style: const TextStyle(
                                color: Color(0xFFFF6B6B), fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              SizedBox(height: Responsive.h(context, 24)),
              // Connect button
              Padding(
                padding: EdgeInsets.symmetric(horizontal: Responsive.w(context, 24)),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _handleConnect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.neonGreen,
                      foregroundColor: Colors.black,
                      padding: EdgeInsets.symmetric(vertical: Responsive.h(context, 16)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Responsive.r(context, 14)),
                      ),
                      elevation: 0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _connecting
                              ? 'Connecting...'
                              : (_ble.connectionState.value ==
                                      BleConnectionState.error
                                  ? 'Retry'
                                  : 'Connect'),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward_rounded, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: Responsive.h(context, 16)),
              TextButton(
                onPressed: () {
                  Navigator.pushReplacementNamed(context, '/home');
                },
                child: const Text(
                  'Skip for now',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
              SizedBox(height: Responsive.h(context, 24)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
