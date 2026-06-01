import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_constants.dart';
import '../core/player_controller.dart';
import '../core/state_machine.dart';
import '../services/approval_sse_service.dart';
import '../widgets/adaptive_padding.dart';
import '../widgets/theadbook_logo.dart';

/// Waiting screen — shown while the display is pending admin approval or while
/// content is being loaded for the first time (syncing).
///
/// Behaviour:
///   • Auto-transitions via [PlayerController] state machine — no user action
///     needed after approval.  The SSE stream fires the transition instantly;
///     the 60 s fallback poll is a silent safety net.
///   • Shows a live-connection indicator so the user knows the app is
///     actively listening rather than frozen.
///   • Hardware key can be copied to clipboard with one tap.
///   • Elapsed-wait timer reassures long-waiting users the app is alive.
class WaitingScreen extends StatefulWidget {
  final PlayerController controller;
  const WaitingScreen({super.key, required this.controller});

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen>
    with TickerProviderStateMixin {
  // ── Elapsed timer ────────────────────────────────────────────────────────
  final _startTime = DateTime.now();
  Timer? _clockTimer;
  Duration _elapsed = Duration.zero;

  // ── Copy confirmation ────────────────────────────────────────────────────
  bool _copied = false;
  Timer? _copiedTimer;

  // ── Pulse animation for the live dot ─────────────────────────────────────
  late final AnimationController _pulseAnim;

  @override
  void initState() {
    super.initState();

    _pulseAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _elapsed = DateTime.now().difference(_startTime));
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _copiedTimer?.cancel();
    _pulseAnim.dispose();
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _copyKey() async {
    await Clipboard.setData(ClipboardData(text: widget.controller.hardwareKey));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  String _formatElapsed(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }

  // ── Live-connection indicator ──────────────────────────────────────────────
  Widget _buildLiveIndicator(SseConnectionState state, bool isSyncing) {
    if (isSyncing) return const SizedBox.shrink();

    final (color, label) = switch (state) {
      SseConnectionState.connected    => (const Color(0xFF22C55E), 'Live'),
      SseConnectionState.connecting   => (const Color(0xFFF97316), 'Connecting…'),
      SseConnectionState.reconnecting => (const Color(0xFFF97316), 'Reconnecting…'),
      SseConnectionState.disconnected => (const Color(0xFF6B7280), 'Polling every 60 s'),
    };

    final dot = state == SseConnectionState.connected
        ? FadeTransition(
            opacity: Tween<double>(begin: 0.4, end: 1.0).animate(_pulseAnim),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          )
        : Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }

  // ── Hardware key card ──────────────────────────────────────────────────────
  Widget _buildKeyCard(String key) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Hardware Key',
                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12, letterSpacing: 0.5),
              ),
              Text(
                'Share with your admin',
                style: TextStyle(
                  color: AppConstants.accentOrange.withOpacity(0.8),
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  key,
                  style: TextStyle(
                    color: AppConstants.accentOrange,
                    fontSize: MediaQuery.sizeOf(context).width < 360 ? 13 : 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _copied
                    ? const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 22)
                    : IconButton(
                        key: const ValueKey('copy'),
                        icon: const Icon(Icons.copy_rounded,
                            color: Color(0xFF9CA3AF), size: 20),
                        tooltip: 'Copy key',
                        onPressed: _copyKey,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final padding    = adaptiveScreenPadding(context);
    final logoHeight = adaptiveLogoHeight(context);

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final syncing  = widget.controller.currentState == PlayerState.syncing;
        final sseState = widget.controller.sseState;

        return Scaffold(
          backgroundColor: AppConstants.background,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - padding.vertical,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TheadbookLogo(height: logoHeight),
                        const SizedBox(height: 36),

                        // ── Spinner + status message ───────────────────────
                        const CircularProgressIndicator(
                          color: AppConstants.accentOrange,
                          strokeWidth: 3,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          syncing ? 'Loading content…' : 'Waiting for admin approval',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        if (!syncing) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Your screen will activate automatically once approved.',
                            style: const TextStyle(
                              color: Color(0xFF9CA3AF),
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],

                        const SizedBox(height: 24),

                        // ── Live / polling indicator ───────────────────────
                        _buildLiveIndicator(sseState, syncing),

                        const SizedBox(height: 32),

                        // ── Hardware key card ──────────────────────────────
                        if (!syncing) _buildKeyCard(widget.controller.hardwareKey),

                        const SizedBox(height: 24),

                        // ── Elapsed wait time ──────────────────────────────
                        if (!syncing)
                          Text(
                            'Waiting for ${_formatElapsed(_elapsed)}',
                            style: const TextStyle(
                              color: Color(0xFF4B5563),
                              fontSize: 12,
                            ),
                          ),

                        const SizedBox(height: 32),

                        // ── Reconfigure ────────────────────────────────────
                        if (!syncing)
                          TextButton(
                            onPressed: widget.controller.reconfigure,
                            child: const Text(
                              'Reconfigure',
                              style: TextStyle(color: Color(0xFF6B7280), fontSize: 14),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
