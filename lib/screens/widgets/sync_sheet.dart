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
  final _focusNode       = FocusNode();

  bool    _loading = false;
  String? _error;

  // Offset slider state — driven by RTDB stream.
  double _sliderValue = 0; // ms
  bool   _sliderDragging = false;
  Timer? _offsetDebounce;

  // Pulse animation for LIVE badge.
  late final AnimationController _pulseCtrl;
  late final Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Init slider from current room offset.
    _sliderValue = SyncService.instance.roomOffsetMs.toDouble();
  }

  @override
  void dispose() {
    _stampController.dispose();
    _focusNode.dispose();
    _pulseCtrl.dispose();
    _offsetDebounce?.cancel();
    super.dispose();
  }

  // ── Sync callback (given to SyncService) ─────────────────────────────────

  void _onSync(SyncPacket packet) {
    if (!mounted) return;
    final player = context.read<BloomeePlayerCubit>().bloomeePlayer;

    // Lag = how long ago host sent this, corrected for NTP clock diff.
    final lag = SyncService.instance.ntpNow() - packet.ntpTs;

    // Apply shared room offset on top.
    final correctedMs = (packet.positionMs + lag + SyncService.instance.roomOffsetMs)
        .clamp(0, 9999999);

    player.seek(Duration(milliseconds: correctedMs));
    if (packet.playing) {
      player.play();
    } else {
      player.pause();
    }
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _createRoom() async {
    setState(() => _loading = true);
    await SyncService.instance.createRoom(_onSync);
    if (mounted) setState(() { _loading = false; _sliderValue = 0; });
  }

  Future<void> _joinRoom() async {
    final stamp = _stampController.text.trim().toUpperCase();
    if (stamp.length != 6) {
      setState(() => _error = 'Enter the 6-character code');
      return;
    }
    _focusNode.unfocus();
    setState(() { _loading = true; _error = null; });

    final ok = await SyncService.instance.joinRoom(stamp, _onSync);

    if (mounted) {
      setState(() {
        _loading = false;
        _error   = ok ? null : 'Room not found. Check the code.';
        if (ok) _sliderValue = SyncService.instance.roomOffsetMs.toDouble();
      });
    }
  }

  Future<void> _leaveRoom() async {
    setState(() => _loading = true);
    await SyncService.instance.leaveRoom();
    if (mounted) setState(() { _loading = false; _sliderValue = 0; });
  }

  void _copyStamp(String stamp) {
    Clipboard.setData(ClipboardData(text: stamp));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Code copied!',
          style: Default_Theme.secondoryTextStyle
              .copyWith(color: Default_Theme.themeColor)),
        backgroundColor: Default_Theme.accentColor2,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // ── Offset slider handlers ────────────────────────────────────────────────

  void _onSliderChanged(double v) {
    // Snap to 10ms grid.
    final snapped = (v / 10).round() * 10.0;
    setState(() => _sliderValue = snapped);

    // Debounce RTDB writes while dragging.
    _offsetDebounce?.cancel();
    _offsetDebounce = Timer(const Duration(milliseconds: 80), () {
      SyncService.instance.setRoomOffset(snapped.toInt());
    });
  }

  void _nudgeOffset(int deltaMs) {
    final next = (_sliderValue + deltaMs).clamp(-3000.0, 3000.0);
    setState(() => _sliderValue = next);
    SyncService.instance.setRoomOffset(next.toInt());
  }

  String _formatOffset(double ms) {
    if (ms == 0) return '0 ms';
    final sign = ms > 0 ? '+' : '';
    return '$sign${ms.toInt()} ms';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final role  = SyncService.instance.role;
    final stamp = SyncService.instance.roomCode;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
        child: Container(
          color: Default_Theme.themeColor,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle
              Center(child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
              )),

              _buildHeader(role),
              const SizedBox(height: 28),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.06), end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: switch (role) {
                  SyncRole.none   => _buildIdleBody(),
                  SyncRole.host   => _buildActiveBody(stamp!),
                  SyncRole.member => _buildActiveBody(stamp!),
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
      SyncRole.none   => (Icons.wifi_tethering_rounded,       'Listen Together'),
      SyncRole.host   => (Icons.broadcast_on_personal_rounded, 'Hosting'),
      SyncRole.member => (Icons.headphones_rounded,            'In Room'),
    };

    return Row(children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Default_Theme.accentColor2.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: Default_Theme.accentColor2, size: 22),
      ),
      const SizedBox(width: 14),
      Text(label,
        style: Default_Theme.secondoryTextStyleMedium.copyWith(
          color: Default_Theme.primaryColor1, fontSize: 22)),
      if (role != SyncRole.none) ...[
        const Spacer(),
        _buildLiveBadge(),
      ],
    ]);
  }

  Widget _buildLiveBadge() {
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
              color: Default_Theme.accentColor2.withValues(alpha: 0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 7, height: 7,
              decoration: const BoxDecoration(
                color: Default_Theme.accentColor2, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text('LIVE',
              style: Default_Theme.tertiaryTextStyle.copyWith(
                color: Default_Theme.accentColor2,
                fontSize: 11, letterSpacing: 1.2)),
          ]),
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
        _PrimaryButton(
          label: 'Create a Room',
          icon: Icons.add_circle_outline_rounded,
          loading: _loading,
          onTap: _createRoom,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Row(children: [
            Expanded(child: Divider(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text('or join',
                style: Default_Theme.secondoryTextStyle.copyWith(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
                  fontSize: 13))),
            Expanded(child: Divider(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
          ]),
        ),
        Row(children: [
          Expanded(child: _StampTextField(
            controller: _stampController,
            focusNode: _focusNode,
            error: _error,
            onSubmitted: (_) => _joinRoom(),
          )),
          const SizedBox(width: 10),
          _IconBtn(icon: Icons.arrow_forward_rounded,
              onTap: _loading ? null : _joinRoom),
        ]),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
            style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.accentColor2, fontSize: 12)),
        ],
      ],
    );
  }

  // ── Active body (host + member, same UI) ──────────────────────────────────

  Widget _buildActiveBody(String stamp) {
    final isHost = SyncService.instance.isHost;

    return Column(
      key: ValueKey('active-$stamp'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Stamp display
        GestureDetector(
          onTap: () => _copyStamp(stamp),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
            decoration: BoxDecoration(
              color: Default_Theme.accentColor2.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Default_Theme.accentColor2.withValues(alpha: 0.3),
                width: 1.5),
            ),
            child: Column(children: [
              Text(stamp,
                style: Default_Theme.primaryTextStyle.copyWith(
                  color: Default_Theme.primaryColor1,
                  fontSize: 44, letterSpacing: 10),
                textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.copy_rounded, size: 12,
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.3)),
                const SizedBox(width: 4),
                Text(isHost ? 'share to invite friends' : 'tap to copy',
                  style: Default_Theme.secondoryTextStyle.copyWith(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.3),
                    fontSize: 12)),
              ]),
            ]),
          ),
        ),

        const SizedBox(height: 24),

        // ── Shared Sync Offset ──────────────────────────────────────────────
        // Driven by RTDB stream — anyone who moves it, everyone sees it.
        StreamBuilder<int>(
          stream: SyncService.instance.roomOffsetStream,
          builder: (context, snap) {
            // Update local slider if not currently dragging.
            if (!_sliderDragging && snap.hasData) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_sliderDragging) {
                  setState(() => _sliderValue = snap.data!.toDouble());
                }
              });
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(Icons.tune_rounded,
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                    size: 16),
                  const SizedBox(width: 8),
                  Text('Sync Offset',
                    style: Default_Theme.secondoryTextStyle.copyWith(
                      color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                      fontSize: 13)),
                  const Spacer(),
                  // Offset value badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _sliderValue == 0
                          ? Default_Theme.primaryColor1.withValues(alpha: 0.07)
                          : Default_Theme.accentColor1.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _formatOffset(_sliderValue),
                      style: Default_Theme.secondoryTextStyleMedium.copyWith(
                        color: _sliderValue == 0
                            ? Default_Theme.primaryColor1.withValues(alpha: 0.4)
                            : Default_Theme.accentColor1,
                        fontSize: 13),
                    ),
                  ),
                ]),

                const SizedBox(height: 4),

                // Slider — range ±3000ms, step 10ms
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                    activeTrackColor: Default_Theme.accentColor1,
                    inactiveTrackColor: Default_Theme.primaryColor1.withValues(alpha: 0.12),
                    thumbColor: Default_Theme.accentColor1,
                    overlayColor: Default_Theme.accentColor1.withValues(alpha: 0.15),
                  ),
                  child: Slider(
                    value: _sliderValue.clamp(-3000, 3000),
                    min: -3000,
                    max: 3000,
                    divisions: 600, // 10ms steps across 6000ms range
                    onChangeStart: (_) => setState(() => _sliderDragging = true),
                    onChanged: _onSliderChanged,
                    onChangeEnd: (v) {
                      setState(() => _sliderDragging = false);
                      SyncService.instance.setRoomOffset(v.round());
                    },
                  ),
                ),

                // Fine-nudge buttons ±10ms and ±50ms
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _NudgeBtn(label: '−50ms', onTap: () => _nudgeOffset(-50)),
                    const SizedBox(width: 8),
                    _NudgeBtn(label: '−10ms', onTap: () => _nudgeOffset(-10)),
                    const SizedBox(width: 8),
                    // Reset to zero
                    GestureDetector(
                      onTap: () {
                        setState(() => _sliderValue = 0);
                        SyncService.instance.setRoomOffset(0);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: Default_Theme.primaryColor1.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Default_Theme.primaryColor1.withValues(alpha: 0.12)),
                        ),
                        child: Text('reset',
                          style: Default_Theme.secondoryTextStyle.copyWith(
                            color: Default_Theme.primaryColor1.withValues(alpha: 0.45),
                            fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _NudgeBtn(label: '+10ms', onTap: () => _nudgeOffset(10)),
                    const SizedBox(width: 8),
                    _NudgeBtn(label: '+50ms', onTap: () => _nudgeOffset(50)),
                  ],
                ),

                const SizedBox(height: 4),
                Text(
                  'Positive = you hear it later · everyone in the room sees this',
                  style: Default_Theme.secondoryTextStyle.copyWith(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.28),
                    fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ],
            );
          },
        ),

        const SizedBox(height: 20),
        _LeaveButton(loading: _loading, onTap: _leaveRoom),
      ],
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

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
          boxShadow: [BoxShadow(
            color: Default_Theme.accentColor2.withValues(alpha: 0.35),
            blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: loading
            ? const Center(child: SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 2.5)))
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(label,
                  style: Default_Theme.secondoryTextStyleMedium.copyWith(
                    color: Colors.white, fontSize: 16)),
              ]),
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
            color: Default_Theme.primaryColor1.withValues(alpha: 0.1)),
        ),
        child: loading
            ? const Center(child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(
                  color: Default_Theme.accentColor2, strokeWidth: 2)))
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.logout_rounded,
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                  size: 18),
                const SizedBox(width: 8),
                Text('Leave Room',
                  style: Default_Theme.secondoryTextStyle.copyWith(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                    fontSize: 15)),
              ]),
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
    required this.controller, required this.focusNode,
    required this.error,      required this.onSubmitted,
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
        color: Default_Theme.primaryColor1, fontSize: 22, letterSpacing: 5),
      decoration: InputDecoration(
        counterText: '',
        hintText: 'A1B2C3',
        hintStyle: Default_Theme.primaryTextStyle.copyWith(
          color: Default_Theme.primaryColor1.withValues(alpha: 0.2),
          fontSize: 22, letterSpacing: 5),
        filled: true,
        fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: error != null
                ? Default_Theme.accentColor2
                : Default_Theme.primaryColor1.withValues(alpha: 0.1))),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: error != null
                ? Default_Theme.accentColor2.withValues(alpha: 0.5)
                : Default_Theme.primaryColor1.withValues(alpha: 0.1))),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Default_Theme.accentColor1)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
        width: 52, height: 52,
        decoration: BoxDecoration(
          color: Default_Theme.accentColor1.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Default_Theme.accentColor1.withValues(alpha: 0.3))),
        child: Icon(icon, color: Default_Theme.accentColor1, size: 22),
      ),
    );
  }
}

class _NudgeBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NudgeBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Default_Theme.accentColor1.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Default_Theme.accentColor1.withValues(alpha: 0.25)),
        ),
        child: Text(label,
          style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.accentColor1, fontSize: 12)),
      ),
    );
  }
}
