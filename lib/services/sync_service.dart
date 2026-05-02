import 'dart:async';
import 'dart:developer';
import 'dart:math' hide log;

import 'package:firebase_database/firebase_database.dart';

typedef SyncCallback = void Function(SyncPacket packet, int localNowMs);

// ─── Model ───────────────────────────────────────────────────────────────────

class SyncPacket {
  final String trackId;
  final int positionMs;
  final bool playing;
  final int serverMs;
  // Track metadata — lets guests load the song even if not in their queue.
  final String trackTitle;
  final String trackArtist;
  final String trackThumbnail;
  final int? trackDurationMs;

  const SyncPacket({
    required this.trackId,
    required this.positionMs,
    required this.playing,
    required this.serverMs,
    this.trackTitle = '',
    this.trackArtist = '',
    this.trackThumbnail = '',
    this.trackDurationMs,
  });

  factory SyncPacket.fromMap(Map<Object?, Object?> map) {
    return SyncPacket(
      trackId: (map['trackId'] as String?) ?? '',
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      playing: (map['playing'] as bool?) ?? false,
      serverMs: (map['ts'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      trackTitle: (map['trackTitle'] as String?) ?? '',
      trackArtist: (map['trackArtist'] as String?) ?? '',
      trackThumbnail: (map['trackThumbnail'] as String?) ?? '',
      trackDurationMs: (map['trackDurationMs'] as num?)?.toInt(),
    );
  }
}

// ─── Role ────────────────────────────────────────────────────────────────────

enum SyncRole { none, host, guest }

// ─── Service ─────────────────────────────────────────────────────────────────

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

  /// Stream of connected guest count — only valid when hosting.
  Stream<int>? get guestCountStream {
    if (_role != SyncRole.host || _roomRef == null) return null;
    return _roomRef!.child('guests').onValue.map(
      (e) => (e.snapshot.value as int?) ?? 0,
    );
  }

  // ── Room management ────────────────────────────────────────────────────────

  static String _generateStamp() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Future<String> createRoom() async {
    await leaveRoom();
    _roomCode = _generateStamp();
    _role = SyncRole.host;
    _roomRef = FirebaseDatabase.instance.ref('syncRooms/$_roomCode');
    // Initialize with guests counter at 0
    await _roomRef!.set({'host': true, 'ts': ServerValue.timestamp, 'guests': 0});
    log('SyncService: created room $_roomCode', name: 'SyncService');
    return _roomCode!;
  }

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

    // Write presence so host sees the connection
    await _roomRef!.child('guests').set(ServerValue.increment(1));

    _guestSub = ref.onValue.listen(
      (event) {
        final raw = event.snapshot.value;
        if (raw == null || raw is! Map) return;
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

  Future<void> leaveRoom() async {
    await _guestSub?.cancel();
    _guestSub = null;

    if (_role == SyncRole.guest && _roomRef != null) {
      // Decrement guest count on leave
      await _roomRef!.child('guests').set(ServerValue.increment(-1)).catchError(
        (Object e) =>
            log('SyncService: decrement error $e', name: 'SyncService'),
      );
    }

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

  // ── Host push ─────────────────────────────────────────────────────────────

  /// Push current playback state to guests.
  /// Uses update() to preserve the guests counter.
  /// Track metadata lets guests load the song even if not in their queue.
  void pushState({
    required String trackId,
    required int positionMs,
    required bool playing,
    String trackTitle = '',
    String trackArtist = '',
    String trackThumbnail = '',
    int? trackDurationMs,
  }) {
    if (_role != SyncRole.host || _roomRef == null) return;

    final data = <String, dynamic>{
      'trackId': trackId,
      'positionMs': positionMs,
      'playing': playing,
      'ts': ServerValue.timestamp,
      'trackTitle': trackTitle,
      'trackArtist': trackArtist,
      'trackThumbnail': trackThumbnail,
      if (trackDurationMs != null) 'trackDurationMs': trackDurationMs,
    };

    _roomRef!
        .update(data)
        .catchError(
          (Object e) =>
              log('SyncService: push error $e', name: 'SyncService'),
        );
  }
}
