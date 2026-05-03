import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:modal_bottom_sheet/modal_bottom_sheet.dart';
import 'package:Bloomee/core/adapters/track_adapter.dart';
import 'package:Bloomee/core/models/exported.dart' hide MediaItem;
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/services/bloomee_player.dart';
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

enum _View { groups, createGroup, joinGroup, session }

class _SyncSheet extends StatefulWidget {
  const _SyncSheet();
  @override
  State<_SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<_SyncSheet>
    with SingleTickerProviderStateMixin {

  // Player captured once in initState — safe to reference after sheet closes.
  late final BloomeePlayer _player;

  // Pending one-shot sub that fires seek after a track-switch loads.
  // Lives on the state object — works even after sheet disposal.
  StreamSubscription<MediaItem?>? _pendingSeekSub;

  _View _view = _View.groups;

  List<SavedGroup> _groups = [];
  bool  _groupsLoading = true;
  bool  _loading       = false;
  String? _error;

  // Form controllers
  final _nameCtrl  = TextEditingController();
  final _codeCtrl  = TextEditingController();
  final _focusNode = FocusNode();

  // Offset sliders
  final Map<String, double> _sliderValues   = {};
  final Set<String>         _dragging       = {};
  final Map<String, Timer>  _debounceTimers = {};

  // Pulse animation for LIVE badge
  late final AnimationController _pulseCtrl;
  late final Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();
    _player = context.read<BloomeePlayerCubit>().bloomeePlayer;

    // If already in a session, go straight to session view.
    if (SyncService.instance.isActive) _view = _View.session;

    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _loadGroups();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _focusNode.dispose();
    _pulseCtrl.dispose();
    _pendingSeekSub?.cancel();
    for (final t in _debounceTimers.values) t.cancel();
    super.dispose();
  }

  // ── Group loading ─────────────────────────────────────────────────────────

  Future<void> _loadGroups() async {
    final groups = await GroupStore.load();
    if (mounted) setState(() { _groups = groups; _groupsLoading = false; });
  }

  // ── Sync callback ─────────────────────────────────────────────────────────
  //
  // Captures _player from field — no `context`, no `mounted` check needed.
  // Works correctly even after the sheet is dismissed.

  void _onSync(SyncPacket packet) {
    final lag         = (SyncService.instance.ntpNow() - packet.ntpTs).clamp(-5000, 5000);
    final myOffset    = SyncService.instance.myOffsetMs;
    final correctedMs = (packet.positionMs + lag + myOffset).clamp(0, 9999999);

    final currentId = _player.mediaItem.valueOrNull?.id;

    if (currentId == packet.trackId) {
      _pendingSeekSub?.cancel();
      _pendingSeekSub = null;

      // Only seek on drift > 2 s — avoids constant choppy re-seeks.
      final drift = (_player.engine.position.inMilliseconds - correctedMs).abs();
      if (drift > 2000) _player.seek(Duration(milliseconds: correctedMs));

      if (packet.playing && !_player.engine.playing)       _player.play();
      else if (!packet.playing && _player.engine.playing)  _player.pause();
    } else {
      _pendingSeekSub?.cancel();
      _pendingSeekSub = null;

      final queue = _player.queue.valueOrNull ?? [];
      final idx   = queue.indexWhere((mi) => mi.id == packet.trackId);

      if (idx >= 0) {
        _player.skipToQueueItem(idx);
      } else if (packet.trackTitle.isNotEmpty) {
        final track = Track(
          id:         packet.trackId,
          title:      packet.trackTitle,
          artists:    packet.trackArtist.isNotEmpty
              ? [ArtistSummary(id: '', name: packet.trackArtist)]
              : [],
          thumbnail:  Artwork(url: packet.trackThumbnail, layout: ImageLayout.square),
          durationMs: packet.trackDurationMs != null
              ? BigInt.from(packet.trackDurationMs!)
              : null,
          isExplicit: false,
        );
        _player.loadPlaylist(
          tracksToPlaylist('Synced', [track]),
          idx: 0, doPlay: packet.playing,
        );
      } else {
        return;
      }

      // Seek once the track is confirmed loaded.
      _pendingSeekSub = _player.mediaItem.listen((mi) {
        if (mi?.id == packet.trackId) {
          _pendingSeekSub?.cancel();
          _pendingSeekSub = null;
          _player.seek(Duration(milliseconds: correctedMs));
          if (packet.playing) _player.play(); else _player.pause();
        }
      });
    }
  }

  // ── Connect / disconnect ──────────────────────────────────────────────────

  Future<void> _connectToGroup(SavedGroup group) async {
    setState(() => _loading = true);
    await SyncService.instance.connectSession(
      group.code,
      onSync:      _onSync,
      onSeek:      _player.seek,
      getPosition: () => _player.engine.position,
    );
    if (mounted) setState(() { _loading = false; _view = _View.session; });
  }

  Future<void> _disconnect() async {
    setState(() => _loading = true);
    _pendingSeekSub?.cancel();
    _pendingSeekSub = null;
    await SyncService.instance.disconnectSession();
    if (mounted) setState(() { _loading = false; _view = _View.groups; });
  }

  // ── Create group ──────────────────────────────────────────────────────────

  Future<void> _createGroup() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    _focusNode.unfocus();
    setState(() { _loading = true; _error = null; });

    final group = await SyncService.instance.createGroup(name);
    await _loadGroups();
    await SyncService.instance.connectSession(
      group.code,
      onSync:      _onSync,
      onSeek:      _player.seek,
      getPosition: () => _player.engine.position,
    );
    _nameCtrl.clear();
    if (mounted) setState(() { _loading = false; _view = _View.session; });
  }

  // ── Join group ────────────────────────────────────────────────────────────

  Future<void> _joinGroup() async {
    final code = _codeCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-character code');
      return;
    }
    _focusNode.unfocus();
    setState(() { _loading = true; _error = null; });

    final group = await SyncService.instance.joinGroup(code);
    if (group == null) {
      if (mounted) setState(() { _loading = false; _error = 'Group not found.'; });
      return;
    }
    await _loadGroups();
    await SyncService.instance.connectSession(
      group.code,
      onSync:      _onSync,
      onSeek:      _player.seek,
      getPosition: () => _player.engine.position,
    );
    _codeCtrl.clear();
    if (mounted) setState(() { _loading = false; _view = _View.session; });
  }

  // ── Leave group ───────────────────────────────────────────────────────────

  Future<void> _leaveGroup() async {
    final code = SyncService.instance.activeCode;
    if (code == null) return;
    setState(() => _loading = true);
    _pendingSeekSub?.cancel();
    _pendingSeekSub = null;
    await SyncService.instance.leaveGroup(code);
    await _loadGroups();
    if (mounted) setState(() { _loading = false; _view = _View.groups; });
  }

  // ── Slider logic ──────────────────────────────────────────────────────────

  double _sliderFor(SyncDevice d) =>
      _sliderValues[d.deviceId] ?? d.offsetMs.toDouble();

  void _onSliderChanged(String id, double v) {
    final snapped = (v / 10).round() * 10.0;
    setState(() => _sliderValues[id] = snapped);
    _debounceTimers[id]?.cancel();
    _debounceTimers[id] = Timer(const Duration(milliseconds: 80), () {
      SyncService.instance.setDeviceOffset(id, snapped.toInt());
    });
  }

  void _onSliderEnd(String id, double v) {
    _dragging.remove(id);
    _debounceTimers[id]?.cancel();
    SyncService.instance.setDeviceOffset(id, v.round());
  }

  void _nudge(String id, double current, int delta) {
    final next = (current + delta).clamp(-3000.0, 3000.0);
    setState(() => _sliderValues[id] = next);
    SyncService.instance.setDeviceOffset(id, next.toInt());
  }

  String _fmtOffset(double ms) {
    if (ms == 0) return '0 ms';
    return '${ms > 0 ? '+' : ''}${ms.toInt()} ms';
  }

  void _copyCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Code copied!',
        style: Default_Theme.secondoryTextStyle.copyWith(color: Default_Theme.themeColor)),
      backgroundColor: Default_Theme.accentColor2,
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
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
                  borderRadius: BorderRadius.circular(4)),
              )),

              _buildHeader(),
              const SizedBox(height: 22),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.05), end: Offset.zero).animate(anim),
                    child: child)),
                child: switch (_view) {
                  _View.groups      => _buildGroupsBody(),
                  _View.createGroup => _buildCreateBody(),
                  _View.joinGroup   => _buildJoinBody(),
                  _View.session     => _buildSessionBody(),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    final inSession = _view == _View.session;

    return Row(children: [
      // Back button when in sub-view or session
      if (_view != _View.groups && _view != _View.session)
        GestureDetector(
          onTap: () => setState(() { _view = _View.groups; _error = null; }),
          child: Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.arrow_back_rounded,
              color: Default_Theme.primaryColor1.withValues(alpha: 0.5), size: 18)),
        ),

      // Icon
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Default_Theme.accentColor2.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14)),
        child: Icon(
          inSession ? Icons.headphones_rounded : Icons.people_rounded,
          color: Default_Theme.accentColor2, size: 22)),
      const SizedBox(width: 14),

      // Title + device name
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          switch (_view) {
            _View.groups      => 'Listen Together',
            _View.createGroup => 'New Group',
            _View.joinGroup   => 'Join Group',
            _View.session     => _groupNameForCode(SyncService.instance.activeCode),
          },
          style: Default_Theme.secondoryTextStyleMedium.copyWith(
            color: Default_Theme.primaryColor1, fontSize: 20)),
        if (inSession)
          Text(SyncService.instance.deviceName,
            style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.4), fontSize: 12)),
      ]),

      const Spacer(),

      // LIVE badge in session, + button on groups list
      if (inSession)
        _buildLiveBadge()
      else if (_view == _View.groups)
        _buildAddButton(),
    ]);
  }

  String _groupNameForCode(String? code) {
    if (code == null) return 'Session';
    return _groups.firstWhere((g) => g.code == code,
        orElse: () => SavedGroup(code: code, name: code)).name;
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
          border: Border.all(color: Default_Theme.accentColor2.withValues(alpha: 0.4))),
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

  Widget _buildAddButton() => Row(mainAxisSize: MainAxisSize.min, children: [
    _SmallBtn(
      icon: Icons.add_rounded,
      label: 'Create',
      onTap: () => setState(() { _view = _View.createGroup; _error = null; }),
    ),
    const SizedBox(width: 8),
    _SmallBtn(
      icon: Icons.link_rounded,
      label: 'Join',
      onTap: () => setState(() { _view = _View.joinGroup; _error = null; }),
    ),
  ]);

  // ── Groups list ───────────────────────────────────────────────────────────

  Widget _buildGroupsBody() {
    if (_groupsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator(
          color: Default_Theme.accentColor2, strokeWidth: 2)),
      );
    }

    if (_groups.isEmpty) {
      return Column(
        key: const ValueKey('empty'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Icon(Icons.people_outline_rounded,
            size: 48, color: Default_Theme.primaryColor1.withValues(alpha: 0.15)),
          const SizedBox(height: 14),
          Text('No groups yet',
            style: Default_Theme.secondoryTextStyleMedium.copyWith(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.35), fontSize: 16)),
          const SizedBox(height: 6),
          Text('Create or join a group to listen together',
            style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.25), fontSize: 13),
            textAlign: TextAlign.center),
          const SizedBox(height: 28),
          Row(children: [
            Expanded(child: _PrimaryButton(
              label: 'Create a Group', icon: Icons.add_circle_outline_rounded,
              loading: false, onTap: () => setState(() => _view = _View.createGroup))),
            const SizedBox(width: 12),
            Expanded(child: _OutlineButton(
              label: 'Join by Code', icon: Icons.link_rounded,
              loading: false, onTap: () => setState(() => _view = _View.joinGroup))),
          ]),
        ],
      );
    }

    return Column(
      key: const ValueKey('groups-list'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._groups.map(_buildGroupTile),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildGroupTile(SavedGroup group) {
    return GestureDetector(
      onTap: _loading ? null : () => _connectToGroup(group),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Default_Theme.primaryColor1.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.08))),
        child: Row(children: [
          // Group icon
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: Default_Theme.accentColor2.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.people_rounded,
              color: Default_Theme.accentColor2, size: 20)),
          const SizedBox(width: 14),

          // Name + code
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(group.name,
                style: Default_Theme.secondoryTextStyleMedium.copyWith(
                  color: Default_Theme.primaryColor1, fontSize: 15),
                overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(group.code,
                style: Default_Theme.secondoryTextStyle.copyWith(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.35),
                  fontSize: 12, letterSpacing: 2)),
            ],
          )),

          // Online count
          StreamBuilder<int>(
            stream: SyncService.instance.onlineCountStream(group.code),
            builder: (_, snap) {
              final count = snap.data ?? 0;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: count > 0
                      ? Default_Theme.accentColor1.withValues(alpha: 0.12)
                      : Default_Theme.primaryColor1.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 6, height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: count > 0
                          ? Default_Theme.accentColor1
                          : Default_Theme.primaryColor1.withValues(alpha: 0.2))),
                  const SizedBox(width: 5),
                  Text('$count',
                    style: Default_Theme.secondoryTextStyle.copyWith(
                      color: count > 0
                          ? Default_Theme.accentColor1
                          : Default_Theme.primaryColor1.withValues(alpha: 0.3),
                      fontSize: 12)),
                ]),
              );
            },
          ),

          const SizedBox(width: 8),
          Icon(Icons.chevron_right_rounded,
            color: Default_Theme.primaryColor1.withValues(alpha: 0.2), size: 20),
        ]),
      ),
    );
  }

  // ── Create group ──────────────────────────────────────────────────────────

  Widget _buildCreateBody() => Column(
    key: const ValueKey('create'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _nameCtrl,
        focusNode: _focusNode,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _createGroup(),
        style: Default_Theme.secondoryTextStyleMedium.copyWith(
          color: Default_Theme.primaryColor1, fontSize: 18),
        decoration: InputDecoration(
          hintText: 'Group name',
          hintStyle: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.25), fontSize: 18),
          filled: true,
          fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.05),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Default_Theme.accentColor1)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16)),
      ),
      const SizedBox(height: 14),
      _PrimaryButton(
        label: 'Create', icon: Icons.add_circle_outline_rounded,
        loading: _loading, onTap: _createGroup),
    ],
  );

  // ── Join group ────────────────────────────────────────────────────────────

  Widget _buildJoinBody() => Column(
    key: const ValueKey('join'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(children: [
        Expanded(child: TextField(
          controller: _codeCtrl,
          focusNode: _focusNode,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          maxLength: 6,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _joinGroup(),
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
              borderSide: BorderSide(color: _error != null
                  ? Default_Theme.accentColor2
                  : Default_Theme.primaryColor1.withValues(alpha: 0.1))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: _error != null
                  ? Default_Theme.accentColor2.withValues(alpha: 0.5)
                  : Default_Theme.primaryColor1.withValues(alpha: 0.1))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Default_Theme.accentColor1)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
        )),
        const SizedBox(width: 10),
        _IconBtn(icon: Icons.arrow_forward_rounded,
          onTap: _loading ? null : _joinGroup),
      ]),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: Default_Theme.secondoryTextStyle.copyWith(
          color: Default_Theme.accentColor2, fontSize: 12)),
      ],
    ],
  );

  // ── Session body ──────────────────────────────────────────────────────────

  Widget _buildSessionBody() {
    final code = SyncService.instance.activeCode ?? '';

    return Column(
      key: const ValueKey('session'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Code display
        GestureDetector(
          onTap: () => _copyCode(code),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Default_Theme.accentColor2.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Default_Theme.accentColor2.withValues(alpha: 0.2), width: 1.5)),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(code, style: Default_Theme.primaryTextStyle.copyWith(
                color: Default_Theme.primaryColor1, fontSize: 28, letterSpacing: 8)),
              const SizedBox(width: 10),
              Icon(Icons.copy_rounded, size: 14,
                color: Default_Theme.primaryColor1.withValues(alpha: 0.3)),
            ]),
          ),
        ),

        const SizedBox(height: 18),

        // Offset sliders header
        Row(children: [
          Icon(Icons.tune_rounded, size: 15,
            color: Default_Theme.primaryColor1.withValues(alpha: 0.4)),
          const SizedBox(width: 6),
          Text('Sync Offsets', style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.4), fontSize: 13)),
          const Spacer(),
          Text('drag anyone\'s', style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.25), fontSize: 11)),
        ]),
        const SizedBox(height: 10),

        StreamBuilder<List<SyncDevice>>(
          stream: SyncService.instance.onlineStream,
          builder: (_, snap) {
            final devices = snap.data ?? [];
            if (devices.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('Waiting for others…',
                  style: Default_Theme.secondoryTextStyle.copyWith(
                    color: Default_Theme.primaryColor1.withValues(alpha: 0.3),
                    fontSize: 13),
                  textAlign: TextAlign.center));
            }
            return Column(children: devices.map(_buildDeviceTile).toList());
          },
        ),

        const SizedBox(height: 14),

        // Leave session / leave group
        Row(children: [
          Expanded(child: _OutlineButton(
            label: 'Leave Session',
            icon: Icons.logout_rounded,
            loading: _loading,
            onTap: _disconnect,
          )),
          const SizedBox(width: 10),
          _IconBtn(
            icon: Icons.group_remove_rounded,
            onTap: _loading ? null : () => _showLeaveGroupDialog(),
            color: Default_Theme.accentColor2.withValues(alpha: 0.7),
          ),
        ]),
      ],
    );
  }

  void _showLeaveGroupDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Default_Theme.themeColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Leave Group?',
          style: Default_Theme.secondoryTextStyleMedium.copyWith(
            color: Default_Theme.primaryColor1)),
        content: Text(
          'You\'ll be removed from the group permanently. You can rejoin with the code.',
          style: Default_Theme.secondoryTextStyle.copyWith(
            color: Default_Theme.primaryColor1.withValues(alpha: 0.6))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.primaryColor1.withValues(alpha: 0.5)))),
          TextButton(
            onPressed: () { Navigator.pop(context); _leaveGroup(); },
            child: Text('Leave', style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.accentColor2))),
        ],
      ),
    );
  }

  // ── Device tile ───────────────────────────────────────────────────────────

  Widget _buildDeviceTile(SyncDevice device) {
    final isMe    = device.deviceId == SyncService.instance.deviceId;
    final current = _sliderFor(device);
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
        border: Border.all(color: isMe
            ? Default_Theme.accentColor1.withValues(alpha: 0.2)
            : Default_Theme.primaryColor1.withValues(alpha: 0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(width: 8, height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: isMe ? Default_Theme.accentColor1
                  : Default_Theme.accentColor2.withValues(alpha: 0.6))),
          const SizedBox(width: 8),
          Text(device.name, style: Default_Theme.secondoryTextStyleMedium.copyWith(
            color: isMe ? Default_Theme.accentColor1 : Default_Theme.primaryColor1,
            fontSize: 14)),
          if (isMe) ...[
            const SizedBox(width: 6),
            Text('(you)', style: Default_Theme.secondoryTextStyle.copyWith(
              color: Default_Theme.accentColor1.withValues(alpha: 0.6), fontSize: 11)),
          ],
          const Spacer(),
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

        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            activeTrackColor:   isMe ? Default_Theme.accentColor1 : Default_Theme.accentColor2,
            inactiveTrackColor: Default_Theme.primaryColor1.withValues(alpha: 0.1),
            thumbColor:         isMe ? Default_Theme.accentColor1 : Default_Theme.accentColor2,
            overlayColor:       isMe
                ? Default_Theme.accentColor1.withValues(alpha: 0.15)
                : Default_Theme.accentColor2.withValues(alpha: 0.15),
          ),
          child: Slider(
            value: current.clamp(-3000, 3000),
            min: -3000, max: 3000, divisions: 600,
            onChangeStart: (_) => _dragging.add(device.deviceId),
            onChanged:     (v) => _onSliderChanged(device.deviceId, v),
            onChangeEnd:   (v) => _onSliderEnd(device.deviceId, v),
          ),
        ),

        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _NudgeBtn(label: '−50', onTap: () => _nudge(device.deviceId, current, -50)),
          const SizedBox(width: 6),
          _NudgeBtn(label: '−10', onTap: () => _nudge(device.deviceId, current, -10)),
          const SizedBox(width: 6),
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
              child: Text('reset', style: Default_Theme.secondoryTextStyle.copyWith(
                color: Default_Theme.primaryColor1.withValues(alpha: 0.4), fontSize: 11)),
            ),
          ),
          const SizedBox(width: 6),
          _NudgeBtn(label: '+10', onTap: () => _nudge(device.deviceId, current, 10)),
          const SizedBox(width: 6),
          _NudgeBtn(label: '+50', onTap: () => _nudge(device.deviceId, current, 50)),
        ]),
      ]),
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
      padding: const EdgeInsets.symmetric(vertical: 15),
      decoration: BoxDecoration(
        color: Default_Theme.accentColor2,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Default_Theme.accentColor2.withValues(alpha: 0.3),
          blurRadius: 16, offset: const Offset(0, 6))]),
      child: loading
          ? const Center(child: SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)))
          : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(label, style: Default_Theme.secondoryTextStyleMedium
                  .copyWith(color: Colors.white, fontSize: 15)),
            ]),
    ),
  );
}

class _OutlineButton extends StatelessWidget {
  final String label; final IconData icon;
  final bool loading; final VoidCallback onTap;
  const _OutlineButton({required this.label, required this.icon,
    required this.loading, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: loading ? null : onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        color: Default_Theme.primaryColor1.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
      child: loading
          ? const Center(child: SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(
                color: Default_Theme.accentColor2, strokeWidth: 2)))
          : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: Default_Theme.primaryColor1.withValues(alpha: 0.45), size: 17),
              const SizedBox(width: 8),
              Text(label, style: Default_Theme.secondoryTextStyle.copyWith(
                color: Default_Theme.primaryColor1.withValues(alpha: 0.45), fontSize: 14)),
            ]),
    ),
  );
}

class _SmallBtn extends StatelessWidget {
  final IconData icon; final String label; final VoidCallback onTap;
  const _SmallBtn({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Default_Theme.accentColor2.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Default_Theme.accentColor2.withValues(alpha: 0.3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Default_Theme.accentColor2, size: 15),
        const SizedBox(width: 5),
        Text(label, style: Default_Theme.secondoryTextStyle.copyWith(
          color: Default_Theme.accentColor2, fontSize: 12)),
      ]),
    ),
  );
}

class _IconBtn extends StatelessWidget {
  final IconData icon; final VoidCallback? onTap; final Color? color;
  const _IconBtn({required this.icon, this.onTap, this.color});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 48, height: 48,
      decoration: BoxDecoration(
        color: Default_Theme.primaryColor1.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Default_Theme.primaryColor1.withValues(alpha: 0.1))),
      child: Icon(icon,
        color: color ?? Default_Theme.primaryColor1.withValues(alpha: 0.4), size: 20)),
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
        border: Border.all(color: Default_Theme.accentColor1.withValues(alpha: 0.25))),
      child: Text(label, style: Default_Theme.secondoryTextStyle.copyWith(
        color: Default_Theme.accentColor1, fontSize: 11)),
    ),
  );
}
