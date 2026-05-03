import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:modal_bottom_sheet/modal_bottom_sheet.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/services/sync_service.dart';
import 'package:Bloomee/blocs/media_player/bloomee_player_cubit.dart';
import 'package:Bloomee/services/bloomee_player.dart';
import 'package:audio_service/audio_service.dart';
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

  // Per-device local slider values — keyed by deviceId.
  // Kept locally while dragging to avoid RTDB round-trip jitter.
  final Map<String, double> _sliderValues    = {};
  final Set<String>         _dragging        = {};
  final Map<String, Timer>  _debounceTimers  = {};

  late final AnimationController _pulseCtrl;
  late final Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _stampController.dispose();
    _focusNode.dispose();
    _pulseCtrl.dispose();
    for (final t in _debounceTimers.values) t.cancel();
    super.dispose();
  }

  // ── Sync callback ─────────────────────────────────────────────────────────
  //
  // Player captured at join/create time — callback survives sheet dismissal.
  // No `mounted`, no `context` — completely decoupled from widget lifecycle.

  SyncCallback _makeCallback(BloomeeMusicPlayer player) {
    return (SyncPacket packet) {
      final lag         = SyncService.instance.ntpNow() - packet.ntpTs;
      final correctedMs = (packet.positionMs + lag + SyncService.instance.myOffsetMs)
          .clamp(0, 9999999);
      final corrected   = Duration(milliseconds: correctedMs);

      final currentId = player.mediaItem.valueOrNull?.id;
      if (currentId != packet.trackId && packet.trackId.isNotEmpty) {
        // Different track — resolve + play directly from trackId (plugin resolves stream URL)
        final mi = MediaItem(
          id:       packet.trackId,
          title:    packet.trackTitle.isNotEmpty  ? packet.trackTitle  : 'Unknown',
          artist:   packet.trackArtist.isNotEmpty ? packet.trackArtist : '',
          artUri:   packet.trackThumbnail.isNotEmpty
                        ? Uri.tryParse(packet.trackThumbnail)
                        : null,
          duration: packet.trackDurationMs != null
                        ? Duration(milliseconds: packet.trackDurationMs!)
                        : null,
        );
        player.playMediaItem(mi, initialPosition: corrected);
        // play/pause state applied after track loads
        if (!packet.playing) {
          Future.delayed(const Duration(milliseconds: 500), player.pause);
        }
        return;
      }

      // Same track — just sync position + play state
      player.seek(corrected);
      if (packet.playing) { player.play(); } else { player.pause(); }
    };
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _createRoom() async {
    setState(() => _loading = true);
    final player = context.read<BloomeePlayerCubit>().bloomeePlayer;
    await SyncService.instance.createRoom(
      onSync:      _makeCallback(player),
      onSeek:      player.seek,
      getPosition: () => player.engine.position,
    );
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
    final ok = await SyncService.instance.joinRoom(
      stamp:       stamp,
      onSync:      _makeCallback(player),
      onSeek:      player.seek,
      getPosition: () => player.engine.position,
    );
    if (mounted) setState(() {
      _loading = false;
      _error   = ok ? null : 'Room not found. Check the code.';
    });
  }

  Future<void> _leaveRoom() async {
    setState(() => _loading = true);
    await SyncService.instance.leaveRoom();
    if (mounted) setState(() { _loading = false; _sliderValues.clear(); });
  }

  void _copyStamp(String stamp) {
    Clipboard.setData(ClipboardData(text: stamp));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Code copied!',
        style: Default_Theme.secondoryTextStyle.copyWith(
          color: Default_Theme.themeColor)),
      backgroundColor: Default_Theme.accentColor2,
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  // ── Slider logic ──────────────────────────────────────────────────────────

  double _sliderFor(SyncDevice device) {
    return _sliderValues[device.deviceId] ?? device.offsetMs.toDouble();
  }

  void _onSliderChanged(String deviceId, double v) {
    final snapped = (v / 10).round() * 10.0;
    setState(() => _sliderValues[deviceId] = snapped);

    _debounceTimers[deviceId]?.cancel();
    _debounceTimers[deviceId] = Timer(const Duration(milliseconds: 80), () {
      SyncService.instance.setDeviceOffset(deviceId, snapped.toInt());
    });
  }

  void _onSliderEnd(String deviceId, double v) {
    _dragging.remove(deviceId);
    _debounceTimers[deviceId]?.cancel();
    SyncService.instance.setDeviceOffset(deviceId, v.round());
  }

  void _nudge(String deviceId, double current, int deltaMs) {
    final next = (current + deltaMs).clamp(-3000.0, 3000.0);
    setState(() => _sliderValues[deviceId] = next);
    SyncService.instance.setDeviceOffset(deviceId, next.toInt());
  }

  String _fmtOffset(double ms) {
    if (ms == 0) return '0 ms';
    return '${ms > 0 ? '+' : ''}${ms.toInt()} ms';
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
              // Handle
              Center(child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4)),
              )),

              _buildHeader(role),
              const SizedBox(height: 24),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.06), end: Offset.zero)
                      .animate(anim),
                    child: child)),
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
      SyncRole.none   => (Icons.wifi_tethering_rounded,        'Listen Together'),
      SyncRole.host   => (Icons.broadcast_on_personal_rounded,  'Hosting'),
      SyncRole.member => (Icons.headphones_rounded,             'In Room'),
    };
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Default_Theme.accentColor2.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14)),
        child: Icon(icon, color: Default_Theme.accentColor2, size: 22)),
      const SizedBox(width: 14),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
          style: Default_Theme.secondoryTextStyleMedium.copyWith(
            color: Default_Theme.primaryColor1, fontSize: 20)),
        if (role != SyncRole.none)
          Text(SyncService.instance.deviceName,
            style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
              fontSize: 12)),
      ]),
      if (role != SyncRole.none) ...[
        const Spacer(),
        _buildLiveBadge(),
      ],
    ]);
  }

  Widget _buildLiveBadge() => AnimatedBuilder(
    animation: _pulseAnim,
    builder: (_, __) => Opacity(
      opacity: _pulseAnim.value,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Default_Theme.accentColor2.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Default_Theme.accentColor2.withValues(alpha: 0.4))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7,
            decoration: const BoxDecoration(
              color: Default_Theme.accentColor2, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text('LIVE', style: Default_Theme.tertiaryTextStyle.copyWith(
            color: Default_Theme.accentColor2, fontSize: 11, letterSpacing: 1.2)),
        ]),
      ),
    ),
  );

  // ── Idle body ─────────────────────────────────────────────────────────────

  Widget _buildIdleBody() => Column(
    key: const ValueKey('idle'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _PrimaryButton(
        label: 'Create a Room', icon: Icons.add_circle_outline_rounded,
        loading: _loading, onTap: _createRoom),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Row(children: [
          Expanded(child: Divider(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text('or join', style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
              fontSize: 13))),
          Expanded(child: Divider(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
        ]),
      ),
      Row(children: [
        Expanded(child: _StampTextField(
          controller: _stampController, focusNode: _focusNode,
          error: _error, onSubmitted: (_) => _joinRoom())),
        const SizedBox(width: 10),
        _IconBtn(icon: Icons.arrow_forward_rounded,
          onTap: _loading ? null : _joinRoom),
      ]),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: Default_Theme.secondoryTextStyle.copyWith(
          color: Default_Theme.accentColor2, fontSize: 12)),
      ],
    ],
  );

  // ── Active body ───────────────────────────────────────────────────────────

  Widget _buildActiveBody(String stamp) => Column(
    key: ValueKey('active-$stamp'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Stamp row
      GestureDetector(
        onTap: () => _copyStamp(stamp),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            color: Default_Theme.accentColor2.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Default_Theme.accentColor2.withValues(alpha: 0.25),
              width: 1.5)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(stamp, style: Default_Theme.primaryTextStyle.copyWith(
                color: Default_Theme.primaryColor1,
                fontSize: 32, letterSpacing: 8)),
              const SizedBox(width: 10),
              Icon(Icons.copy_rounded, size: 14,
                color: Default_Theme.primaryColor1.withValues(alpha: 0.3)),
            ]),
        ),
      ),

      const SizedBox(height: 20),

      // Device list header
      Row(children: [
        Icon(Icons.tune_rounded, size: 15,
          color: Default_Theme.primaryColor1.withValues(alpha: 0.4)),
        const SizedBox(width: 6),
        Text('Sync Offsets',
          style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
            fontSize: 13)),
        const Spacer(),
        Text('drag anyone\'s',
          style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.25),
            fontSize: 11)),
      ]),

      const SizedBox(height: 10),

      // Device sliders — live from RTDB
      StreamBuilder<List<SyncDevice>>(
        stream: SyncService.instance.devicesStream,
        builder: (context, snap) {
          final devices = snap.data ?? [];
          if (devices.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('Waiting for devices…',
                style: Default_Theme.secondoryTextStyle.copyWith(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.3),
                  fontSize: 13),
                textAlign: TextAlign.center),
            );
          }
          return Column(
            children: devices.map((d) => _buildDeviceTile(d)).toList(),
          );
        },
      ),

      const SizedBox(height: 16),
      _LeaveButton(loading: _loading, onTap: _leaveRoom),
    ],
  );

  // ── Device tile ───────────────────────────────────────────────────────────

  Widget _buildDeviceTile(SyncDevice device) {
    final isMe    = device.deviceId == SyncService.instance.deviceId;
    final current = _sliderFor(device);

    // If not dragging, sync local value from RTDB (remote changes applied).
    if (!_dragging.contains(device.deviceId)) {
      _sliderValues[device.deviceId] = device.offsetMs.toDouble();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: isMe
            ? Default_Theme.accentColor1.withValues(alpha: 0.08)
            : Default_Theme.primaryColor1.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isMe
              ? Default_Theme.accentColor1.withValues(alpha: 0.2)
              : Default_Theme.primaryColor1.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Name row
          Row(children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isMe
                    ? Default_Theme.accentColor1
                    : Default_Theme.accentColor2.withValues(alpha: 0.6)),
            ),
            const SizedBox(width: 8),
            Text(device.name,
              style: Default_Theme.secondoryTextStyleMedium.copyWith(
                color: isMe
                    ? Default_Theme.accentColor1
                    : Default_Theme.primaryColor1,
                fontSize: 14)),
            if (isMe) ...[
              const SizedBox(width: 6),
              Text('(you)', style: Default_Theme.secondoryTextStyle.copyWith(
                color: Default_Theme.accentColor1.withValues(alpha: 0.6),
                fontSize: 11)),
            ],
            const Spacer(),
            // Offset badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: current == 0
                    ? Default_Theme.primaryColor1.withValues(alpha: 0.07)
                    : Default_Theme.accentColor2.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20)),
              child: Text(_fmtOffset(current),
                style: Default_Theme.secondoryTextStyle.copyWith(
                  color: current == 0
                      ? Default_Theme.primaryColor1.withValues(alpha: 0.4)
                      : Default_Theme.accentColor2,
                  fontSize: 12)),
            ),
          ]),

          // Slider
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: isMe
                  ? Default_Theme.accentColor1
                  : Default_Theme.accentColor2,
              inactiveTrackColor:
                  Default_Theme.primaryColor1.withValues(alpha: 0.1),
              thumbColor: isMe
                  ? Default_Theme.accentColor1
                  : Default_Theme.accentColor2,
              overlayColor: isMe
                  ? Default_Theme.accentColor1.withValues(alpha: 0.15)
                  : Default_Theme.accentColor2.withValues(alpha: 0.15),
            ),
            child: Slider(
              value: current.clamp(-3000, 3000),
              min: -3000, max: 3000,
              divisions: 600,
              onChangeStart: (_) => _dragging.add(device.deviceId),
              onChanged: (v) => _onSliderChanged(device.deviceId, v),
              onChangeEnd:  (v) => _onSliderEnd(device.deviceId, v),
            ),
          ),

          // Fine nudge buttons
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _NudgeBtn(label: '−50', onTap: () => _nudge(device.deviceId, current, -50)),
            const SizedBox(width: 6),
            _NudgeBtn(label: '−10', onTap: () => _nudge(device.deviceId, current, -10)),
            const SizedBox(width: 6),
            // Reset
            GestureDetector(
              onTap: () {
                setState(() => _sliderValues[device.deviceId] = 0);
                SyncService.instance.setDeviceOffset(device.deviceId, 0);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
                child: Text('reset',
                  style: Default_Theme.secondoryTextStyle.copyWith(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.4),
                    fontSize: 11)),
              ),
            ),
            const SizedBox(width: 6),
            _NudgeBtn(label: '+10', onTap: () => _nudge(device.deviceId, current, 10)),
            const SizedBox(width: 6),
            _NudgeBtn(label: '+50', onTap: () => _nudge(device.deviceId, current, 50)),
          ]),
        ],
      ),
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label; final IconData icon;
  final bool loading; final VoidCallback onTap;
  const _PrimaryButton({required this.label, required this.icon,
    required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: loading ? null : onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Default_Theme.accentColor2,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(
          color: Default_Theme.accentColor2.withValues(alpha: 0.35),
          blurRadius: 20, offset: const Offset(0, 8))]),
      child: loading
          ? const Center(child: SizedBox(width: 22, height: 22,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)))
          : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Text(label, style: Default_Theme.secondoryTextStyleMedium
                  .copyWith(color: Colors.white, fontSize: 16)),
            ]),
    ),
  );
}

class _LeaveButton extends StatelessWidget {
  final bool loading; final VoidCallback onTap;
  const _LeaveButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: loading ? null : onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Default_Theme.primaryColor1.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
      child: loading
          ? const Center(child: SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(
                color: Default_Theme.accentColor2, strokeWidth: 2)))
          : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.logout_rounded,
                color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                size: 18),
              const SizedBox(width: 8),
              Text('Leave Room', style: Default_Theme.secondoryTextStyle.copyWith(
                color: Default_Theme.primaryColor1.withValues(alpha: 0.5),
                fontSize: 15)),
            ]),
    ),
  );
}

class _StampTextField extends StatelessWidget {
  final TextEditingController controller; final FocusNode focusNode;
  final String? error; final ValueChanged<String> onSubmitted;
  const _StampTextField({required this.controller, required this.focusNode,
    required this.error, required this.onSubmitted});

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller, focusNode: focusNode,
    textCapitalization: TextCapitalization.characters,
    maxLength: 6, textInputAction: TextInputAction.go,
    onSubmitted: onSubmitted,
    style: Default_Theme.primaryTextStyle.copyWith(
      color: Default_Theme.primaryColor1, fontSize: 22, letterSpacing: 5),
    decoration: InputDecoration(
      counterText: '', hintText: 'A1B2C3',
      hintStyle: Default_Theme.primaryTextStyle.copyWith(
        color: Default_Theme.primaryColor1.withValues(alpha: 0.2),
        fontSize: 22, letterSpacing: 5),
      filled: true,
      fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.05),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: error != null
            ? Default_Theme.accentColor2
            : Default_Theme.primaryColor1.withValues(alpha: 0.1))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: error != null
            ? Default_Theme.accentColor2.withValues(alpha: 0.5)
            : Default_Theme.primaryColor1.withValues(alpha: 0.1))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Default_Theme.accentColor1)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
  );
}

class _IconBtn extends StatelessWidget {
  final IconData icon; final VoidCallback? onTap;
  const _IconBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 52, height: 52,
      decoration: BoxDecoration(
        color: Default_Theme.accentColor1.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Default_Theme.accentColor1.withValues(alpha: 0.3))),
      child: Icon(icon, color: Default_Theme.accentColor1, size: 22)),
  );
}

class _NudgeBtn extends StatelessWidget {
  final String label; final VoidCallback onTap;
  const _NudgeBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Default_Theme.accentColor1.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Default_Theme.accentColor1.withValues(alpha: 0.25))),
      child: Text(label, style: Default_Theme.secondoryTextStyle.copyWith(
        color: Default_Theme.accentColor1, fontSize: 11)),
    ),
  );
}
