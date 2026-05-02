import 'dart:async';
import 'dart:developer';
import 'dart:math';

import 'package:firebase_database/firebase_database.dart';

/// Callback fired on the guest side when the host pushes a state update.
///
/// [packet]     — the host's playback state.
/// [localNowMs] — local clock at the time the callback fired, used for
///               latency correction: correctedPositionMs = packet.positionMs
///               + (localNowMs - packet.serverMs).
typedef SyncCallback = void Function(SyncPacket packet, int localNowMs);

// ─── Model ───────────────────────────────────────────────────────────────────

class SyncPacket {
  /// Composite media ID: "{pluginId}::{localId}"
  final String trackId;

  /// Position the host was at when the packet was written (ms).
  final int positionMs;

  /// Whether the host was playing when the packet was written.
  final bool playing;

  /// Firebase server timestamp (ms since epoch) — used for latency correction.
  final int serverMs;

  const SyncPacket({
    required this.trackId,
    required this.positionMs,
    required this.playing,
    required this.serverMs,
  });

  factory SyncPacket.fromMap(Map<Object?, Object?> map) {
    return SyncPacket(
      trackId: (map['trackId'] as String?) ?? '',
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      playing: (map['playing'] as bool?) ?? false,
      serverMs: (map['ts'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}

// ─── Role ────────────────────────────────────────────────────────────────────

enum SyncRole { none, host, guest }

// ─── Service ─────────────────────────────────────────────────────────────────

/// Firebase RTDB–backed online playback sync.
///
/// ## Usage
///
/// **Host** (the person sharing):
/// ```dart
/// final stamp = await SyncService.instance.createRoom();
/// // share stamp with friends
/// // then hook: call pushState() on play/pause/seek/track change
/// ```
///
/// **Guest** (the person joining):
/// ```dart
/// final ok = await SyncService.instance.joinRoom(stamp, (packet, nowMs) {
///   final lag = nowMs - packet.serverMs;
///   final corrected = Duration(milliseconds: packet.positionMs + lag);
///   player.seek(corrected);
///   if (packet.playing) player.play() else player.pause();
/// });
/// ```
///
/// Call [leaveRoom] on both sides when done.
class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  SyncRole _role = SyncRole.none;
  String? _roomCode;
  DatabaseReference? _roomRef;
  StreamSubscription<DatabaseEvent>? _guestSub;
  SyncCallback? _onSync;

  // ── Getters ────────────────────────────────────────────────────────────────

  SyncRole get role => _role;
  String? get roomCode => _roomCode;
  bool get isActive => _role != SyncRole.none;
  bool get isHost => _role == SyncRole.host;
  bool get isGuest => _role == SyncRole.guest;

  // ── Room management ────────────────────────────────────────────────────────

  /// Generate a random 6-character alphanumeric stamp (no ambiguous chars).
  static String _generateStamp() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Create a new sync room and return the stamp to share with guests.
  ///
  /// Automatically leaves any existing room first.
  Future<String> createRoom() async {
    await leaveRoom();
    _roomCode = _generateStamp();
    _role = SyncRole.host;
    _roomRef = FirebaseDatabase.instance.ref('syncRooms/$_roomCode');
    // Write a placeholder so guests can confirm the room exists.
    await _roomRef!.set({'host': true, 'ts': ServerValue.timestamp});
    log('SyncService: created room $_roomCode', name: 'SyncService');
    return _roomCode!;
  }

  /// Join an existing room by stamp.
  ///
  /// Returns `true` if the room exists, `false` if the stamp is invalid.
  /// [onSync] is called every time the host pushes a new state.
  Future<bool> joinRoom(String stamp, SyncCallback onSync) async {
    await leaveRoom();

    final ref = FirebaseDatabase.instance.ref('syncRooms/$stamp');
    final snap = await ref.get();
    if (!snap.exists) {
      log('SyncService: room $stamp not found', name: 'SyncService');
      return false;
    }

    _roomCode = stamp.toUpperCase();
    _role = SyncRole.guest;
    _roomRef = ref;
    _onSync = onSync;

    _guestSub = ref.onValue.listen(
      (event) {
        final raw = event.snapshot.value;
        if (raw == null || raw is! Map) return;
        // Ignore the initial placeholder written by the host on room creation.
        if (raw['trackId'] == null) return;
        try {
          final packet = SyncPacket.fromMap(raw as Map<Object?, Object?>);
          final localNow = DateTime.now().millisecondsSinceEpoch;
          _onSync?.call(packet, localNow);
        } catch (e) {
          log('SyncService: parse error $e', name: 'SyncService');
        }
      },
      onError: (Object e) =>
          log('SyncService: listener error $e', name: 'SyncService'),
    );

    log('SyncService: joined room $stamp', name: 'SyncService');
    return true;
  }

  /// Leave the current room.
  ///
  /// Hosts delete their room node; guests just cancel the listener.
  Future<void> leaveRoom() async {
    await _guestSub?.cancel();
    _guestSub = null;

    if (_role == SyncRole.host && _roomRef != null) {
      await _roomRef!.remove().catchError(
        (Object e) => log('SyncService: remove error $e', name: 'SyncService'),
      );
    }

    _roomRef = null;
    _roomCode = null;
    _role = SyncRole.none;
    _onSync = null;

    log('SyncService: left room', name: 'SyncService');
  }

  // ── Host push (called from BloomeeMusicPlayer hooks) ──────────────────────

  /// Push the current playback state to all guests.
  ///
  /// No-op when not in host role or room is not active.
  void pushState({
    required String trackId,
    required int positionMs,
    required bool playing,
  }) {
    if (_role != SyncRole.host || _roomRef == null) return;

    _roomRef!
        .set({
          'trackId': trackId,
          'positionMs': positionMs,
          'playing': playing,
          'ts': ServerValue.timestamp, // Firebase writes actual server time
        })
        .catchError(
          (Object e) =>
              log('SyncService: push error $e', name: 'SyncService'),
        );
  }
}
