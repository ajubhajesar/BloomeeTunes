import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:modal_bottom_sheet/modal_bottom_sheet.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/services/sync_service.dart';
import 'package:Bloomee/blocs/media_player/bloomee_player_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// ─── Entry point ─────────────────────────────────────────────────────────────

void showSyncSheet(BuildContext context) {
  showMaterialModalBottomSheet(
    context: context,
    expand: false,
    animationCurve: Curves.easeOutCubic,
    duration: const Duration(milliseconds: 320),
    backgroundColor: Colors.transparent,
    builder: (_) => BlocProvider.value(
      value: context.read<BloomeePlayerCubit>(),
      child: const _SyncSheet(),
    ),
  );
}

// ─── Sheet ────────────────────────────────────────────────────────────────────

class _SyncSheet extends StatefulWidget {
  const _SyncSheet();

  @override
  State<_SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<_SyncSheet>
    with SingleTickerProviderStateMixin {
  final _stampController = TextEditingController();
  final _focusNode = FocusNode();

  bool _loading = false;
  String? _error;

  // Pulse animation for the live indicator
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _stampController.dispose();
    _focusNode.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _createRoom() async {
    setState(() => _loading = true);
    await SyncService.instance.createRoom();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _joinRoom() async {
    final stamp = _stampController.text.trim().toUpperCase();
    if (stamp.length != 6) {
      setState(() => _error = 'Enter the 6-character code');
      return;
    }
    _focusNode.unfocus();
    setState(() { _loading = true; _error = null; });

    final player = context.read<BloomeePlayerCubit>().bloomeePlayer;

    final ok = await SyncService.instance.joinRoom(stamp, (packet, localNowMs) {
      if (!mounted) return;

      // Switch track if host is on a different one
      final currentId = player.mediaItem.valueOrNull?.id;
      if (currentId != packet.trackId) {
        final queue = player.queue.valueOrNull ?? [];
        final idx = queue.indexWhere((mi) => mi.id == packet.trackId);
        if (idx >= 0) {
          player.skipToQueueItem(idx); // fire-and-forget; seek below corrects position
        }
      }

      // Latency-corrected position
      final lag = localNowMs - packet.serverMs;
      final corrected = Duration(
        milliseconds: (packet.positionMs + lag).clamp(0, 9999999),
      );
      player.seek(corrected);
      if (packet.playing) {
        player.play();
      } else {
        player.pause();
      }
    });

    if (mounted) {
      setState(() {
        _loading = false;
        _error = ok ? null : 'Room not found. Check the code.';
      });
    }
  }

  Future<void> _leaveRoom() async {
    setState(() => _loading = true);
    await SyncService.instance.leaveRoom();
    if (mounted) setState(() => _loading = false);
  }

  void _copyStamp(String stamp) {
    Clipboard.setData(ClipboardData(text: stamp));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Code copied!',
          style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.themeColor,
          ),
        ),
        backgroundColor: Default_Theme.accentColor2,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final role = SyncService.instance.role;
    final stamp = SyncService.instance.roomCode;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
        child: Container(
          color: Default_Theme.themeColor,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Drag handle ──
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),

              // ── Header ──
              _buildHeader(role),
              const SizedBox(height: 28),

              // ── Body ──
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.06),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: switch (role) {
                  SyncRole.none => _buildIdleBody(),
                  SyncRole.host => _buildHostBody(stamp!),
                  SyncRole.guest => _buildGuestBody(stamp!),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader(SyncRole role) {
    final (icon, label) = switch (role) {
      SyncRole.none => (Icons.wifi_tethering_rounded, 'Listen Together'),
      SyncRole.host => (Icons.broadcast_on_personal_rounded, 'Hosting'),
      SyncRole.guest => (Icons.headphones_rounded, 'Synced'),
    };

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Default_Theme.accentColor2.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: Default_Theme.accentColor2, size: 22),
        ),
        const SizedBox(width: 14),
        Text(
          label,
          style: Default_Theme.secondoryTextStyleMedium.copyWith(
            color: Default_Theme.primaryColor1,
            fontSize: 22,
          ),
        ),
        if (role != SyncRole.none) ...[
          const Spacer(),
          _buildLiveIndicator(),
        ],
      ],
    );
  }

  Widget _buildLiveIndicator() {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, __) => Opacity(
        opacity: _pulseAnim.value,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Default_Theme.accentColor2.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Default_Theme.accentColor2.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: Default_Theme.accentColor2,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'LIVE',
                style: Default_Theme.tertiaryTextStyle.copyWith(
                  color: Default_Theme.accentColor2,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Idle body ─────────────────────────────────────────────────────────────

  Widget _buildIdleBody() {
    return Column(
      key: const ValueKey('idle'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Create room button
        _PrimaryButton(
          label: 'Create a Room',
          icon: Icons.add_circle_outline_rounded,
          loading: _loading,
          onTap: _createRoom,
        ),

        // Divider
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Row(
            children: [
              Expanded(
                child: Divider(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.1),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  'or join',
                  style: Default_Theme.secondoryTextStyle.copyWith(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
                    fontSize: 13,
                  ),
                ),
              ),
              Expanded(
                child: Divider(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.1),
                ),
              ),
            ],
          ),
        ),

        // Join row
        Row(
          children: [
            Expanded(
              child: _StampTextField(
                controller: _stampController,
                focusNode: _focusNode,
                error: _error,
                onSubmitted: (_) => _joinRoom(),
              ),
            ),
            const SizedBox(width: 10),
            _IconBtn(
              icon: Icons.arrow_forward_rounded,
              onTap: _loading ? null : _joinRoom,
            ),
          ],
        ),

        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.accentColor2,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }

  // ── Host body ─────────────────────────────────────────────────────────────

  Widget _buildHostBody(String stamp) {
    return Column(
      key: const ValueKey('host'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Share this code with friends',
          style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),

        // Big stamp display
        GestureDetector(
          onTap: () => _copyStamp(stamp),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
            decoration: BoxDecoration(
              color: Default_Theme.accentColor2.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Default_Theme.accentColor2.withValues(alpha: 0.3),
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                Text(
                  stamp,
                  style: Default_Theme.primaryTextStyle.copyWith(
                    color: Default_Theme.primaryColor1,
                    fontSize: 48,
                    letterSpacing: 10,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.copy_rounded,
                      size: 13,
                      color:
                          Default_Theme.primaryColor1.withValues(alpha: 0.35),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'tap to copy',
                      style: Default_Theme.secondoryTextStyle.copyWith(
                        color:
                            Default_Theme.primaryColor1.withValues(alpha: 0.35),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Guest count
        StreamBuilder<int>(
          stream: SyncService.instance.guestCountStream,
          builder: (context, snapshot) {
            final count = snapshot.data ?? 0;
            if (count == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Waiting for listeners…',
                  style: Default_Theme.secondoryTextStyle.copyWith(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.35),
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.people_rounded,
                      color: Default_Theme.accentColor1, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    '$count listener${count == 1 ? '' : 's'} connected',
                    style: Default_Theme.secondoryTextStyle.copyWith(
                      color: Default_Theme.accentColor1,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            );
          },
        ),

        const SizedBox(height: 8),

        _LeaveButton(loading: _loading, onTap: _leaveRoom),
      ],
    );
  }

  // ── Guest body ────────────────────────────────────────────────────────────

  Widget _buildGuestBody(String stamp) {
    return Column(
      key: const ValueKey('guest'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          decoration: BoxDecoration(
            color: Default_Theme.accentColor1.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Default_Theme.accentColor1.withValues(alpha: 0.25),
              width: 1.5,
            ),
          ),
          child: Column(
            children: [
              Text(
                'Room code',
                style: Default_Theme.secondoryTextStyle.copyWith(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                stamp,
                style: Default_Theme.primaryTextStyle.copyWith(
                  color: Default_Theme.accentColor1,
                  fontSize: 36,
                  letterSpacing: 8,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Your playback is synced to the host',
          style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
            fontSize: 13,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _LeaveButton(loading: _loading, onTap: _leaveRoom),
      ],
    );
  }
}

// ─── Reusable sub-widgets ─────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool loading;
  final VoidCallback onTap;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Default_Theme.accentColor2,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Default_Theme.accentColor2.withValues(alpha: 0.35),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: loading
            ? const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: Default_Theme.secondoryTextStyleMedium.copyWith(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _LeaveButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;

  const _LeaveButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Default_Theme.primaryColor1.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.1),
          ),
        ),
        child: loading
            ? const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: Default_Theme.accentColor2,
                    strokeWidth: 2,
                  ),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.logout_rounded,
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Leave Room',
                    style: Default_Theme.secondoryTextStyle.copyWith(
                      color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _StampTextField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? error;
  final ValueChanged<String> onSubmitted;

  const _StampTextField({
    required this.controller,
    required this.focusNode,
    required this.error,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      textCapitalization: TextCapitalization.characters,
      maxLength: 6,
      textInputAction: TextInputAction.go,
      onSubmitted: onSubmitted,
      style: Default_Theme.primaryTextStyle.copyWith(
        color: Default_Theme.primaryColor1,
        fontSize: 22,
        letterSpacing: 5,
      ),
      decoration: InputDecoration(
        counterText: '',
        hintText: 'A1B2C3',
        hintStyle: Default_Theme.primaryTextStyle.copyWith(
          color: Default_Theme.primaryColor1.withValues(alpha: 0.2),
          fontSize: 22,
          letterSpacing: 5,
        ),
        filled: true,
        fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: error != null
                ? Default_Theme.accentColor2
                : Default_Theme.primaryColor1.withValues(alpha: 0.1),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: error != null
                ? Default_Theme.accentColor2.withValues(alpha: 0.5)
                : Default_Theme.primaryColor1.withValues(alpha: 0.1),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Default_Theme.accentColor1),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _IconBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: Default_Theme.accentColor1.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Default_Theme.accentColor1.withValues(alpha: 0.3),
          ),
        ),
        child: Icon(
          icon,
          color: Default_Theme.accentColor1,
          size: 22,
        ),
      ),
    );
  }
}
