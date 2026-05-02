import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:math' hide log;
import 'dart:typed_data';

import 'package:firebase_database/firebase_database.dart';

typedef SyncCallback = void Function(SyncPacket packet);

// ─── NTP Clock ───────────────────────────────────────────────────────────────
//
// Ported from AudioBeam's ClockSync.kt (same algorithm).
// Runs 5 UDP rounds against pool.ntp.org + time.google.com,
// picks the min-RTT sample, and caches the offset for the session.
//
// Formula per round:
//   T1 = local send time
//   T2 = server receive time (extracted from NTP response bytes 32–39)
//   T4 = local receive time
//   offset = T2 − (T1 + T4) / 2
//
// Min-RTT selection ensures the sample with least queuing delay is used,
// giving the most accurate one-way estimate (same logic as AudioBeam).

class NtpClock {
  NtpClock._();
  static final NtpClock instance = NtpClock._();

  static const _servers  = ['pool.ntp.org', 'time.google.com'];
  static const _port     = 123;
  static const _delta    = 2208988800; // seconds from 1900 epoch to 1970
  static const _rounds   = 5;
  static const _maxRttMs = 500;
  static const _timeoutMs = 2000;

  int _offsetMs = 0;
  bool _synced  = false;

  /// NTP-corrected current time in ms since epoch.
  int now() => DateTime.now().millisecondsSinceEpoch + _offsetMs;
  bool get synced => _synced;

  /// Runs NTP sync against all servers; keeps going until one succeeds.
  Future<void> sync() async {
    for (final server in _servers) {
      final offset = await _tryServer(server);
      if (offset != null) {
        _offsetMs = offset;
        _synced   = true;
        log('NtpClock: synced via $server offset=${_offsetMs}ms',
            name: 'NtpClock');
        return;
      }
    }
    // All failed — use local clock as-is (offset stays 0).
    _synced = true;
    log('NtpClock: all servers failed, using local clock', name: 'NtpClock');
  }

  Future<int?> _tryServer(String server) async {
    int bestRtt    = _maxRttMs + 1;
    int bestOffset = 0;
    bool got       = false;

    List<InternetAddress> addrs;
    try {
      addrs = await InternetAddress.lookup(server);
    } catch (_) {
      return null;
    }
    final addr = addrs.first;

    for (int i = 0; i < _rounds; i++) {
      RawDatagramSocket? sock;
      try {
        sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        sock.readEventsEnabled = true;

        // NTP request packet — mode 3 (client), version 3
        final req = Uint8List(48)..first = 0x1B;
        final t1  = DateTime.now().millisecondsSinceEpoch;
        sock.send(req, addr, _port);

        // Wait for response with timeout
        Datagram? dg;
        final deadline = t1 + _timeoutMs;
        await for (final ev in sock) {
          if (ev == RawSocketEvent.read) {
            dg = sock.receive();
            break;
          }
          if (DateTime.now().millisecondsSinceEpoch > deadline) break;
        }
        final t4 = DateTime.now().millisecondsSinceEpoch;

        if (dg == null || dg.data.length < 48) continue;

        // Extract server receive timestamp from bytes 32–39 (T2 in NTP)
        // NTP stores seconds in the first 4 bytes of each timestamp field,
        // fractions in the next 4 (we ignore fractions for ms accuracy).
        final data = dg.data;
        int sec = 0;
        for (int b = 32; b < 36; b++) {
          sec = (sec << 8) | (data[b] & 0xFF);
        }
        final t2 = (sec - _delta) * 1000; // convert to Unix ms

        final rtt    = t4 - t1;
        final offset = t2 - (t1 + t4) ~/ 2;

        if (rtt < bestRtt && rtt < _maxRttMs) {
          bestRtt    = rtt;
          bestOffset = offset;
          got        = true;
          log('NtpClock: round $i rtt=${rtt}ms offset=${offset}ms server=$server',
              name: 'NtpClock');
        }
      } catch (e) {
        log('NtpClock: round $i failed: $e', name: 'NtpClock');
      } finally {
        sock?.close();
      }

      if (i < _rounds - 1) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }

    return got ? bestOffset : null;
  }
}

// ─── Model ───────────────────────────────────────────────────────────────────

class SyncPacket {
  final String trackId;
  final int positionMs;
  final bool playing;

  /// NTP-corrected timestamp at the moment the host wrote this packet.
  final int ntpTs;

  final String pushedBy;
  final String trackTitle;
  final String trackArtist;
  final String trackThumbnail;
  final int? trackDurationMs;

  const SyncPacket({
    required this.trackId,
    required this.positionMs,
    required this.playing,
    required this.ntpTs,
    this.pushedBy = '',
    this.trackTitle = '',
    this.trackArtist = '',
    this.trackThumbnail = '',
    this.trackDurationMs,
  });

  factory SyncPacket.fromMap(Map<Object?, Object?> map) {
    return SyncPacket(
      trackId:         (map['trackId']      as String?) ?? '',
      positionMs:      (map['positionMs']   as num?)?.toInt() ?? 0,
      playing:         (map['playing']      as bool?) ?? false,
      ntpTs:           (map['ntpTs']        as num?)?.toInt() ??
                       DateTime.now().millisecondsSinceEpoch,
      pushedBy:        (map['pushedBy']     as String?) ?? '',
      trackTitle:      (map['trackTitle']   as String?) ?? '',
      trackArtist:     (map['trackArtist']  as String?) ?? '',
      trackThumbnail:  (map['trackThumbnail'] as String?) ?? '',
      trackDurationMs: (map['trackDurationMs'] as num?)?.toInt(),
    );
  }
}

// ─── Role ────────────────────────────────────────────────────────────────────

/// [host]   — created the room; cleans it up on leave.
/// [member] — joined by code; equal control (collaborative).
/// [none]   — not in any room.
enum SyncRole { none, host, member }

// ─── Service ─────────────────────────────────────────────────────────────────

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  // Per-session unique device ID — filters our own echo from RTDB.
  final String _deviceId = _randomId();
  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(12, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  SyncRole _role     = SyncRole.none;
  String?  _roomCode;
  DatabaseReference? _roomRef;

  StreamSubscription<DatabaseEvent>? _stateSub;
  StreamSubscription<DatabaseEvent>? _offsetSub;

  SyncCallback? _onSync;

  // Suppress re-broadcasting when we applied an incoming packet.
  bool _syncDriven = false;

  // Shared room offset — lives in RTDB, everyone reads/writes.
  int _roomOffsetMs = 0;

  // ── Getters ───────────────────────────────────────────────────────────────

  SyncRole get role       => _role;
  String?  get roomCode   => _roomCode;
  bool     get isActive   => _role != SyncRole.none;
  bool     get isHost     => _role == SyncRole.host;

  /// Current shared room offset in ms.
  int get roomOffsetMs => _roomOffsetMs;

  /// Stream of member count for this room.
  Stream<int>? get memberCountStream {
    if (_roomRef == null) return null;
    return _roomRef!.child('members').onValue.map(
      (e) => (e.snapshot.value as num?)?.toInt() ?? 0,
    );
  }

  /// Stream of the shared offset — use in UI to keep slider in sync.
  Stream<int>? get roomOffsetStream {
    if (_roomRef == null) return null;
    return _roomRef!.child('roomOffsetMs').onValue.map(
      (e) => (e.snapshot.value as num?)?.toInt() ?? 0,
    );
  }

  // ── NTP ───────────────────────────────────────────────────────────────────

  /// NTP-corrected now. Used for both writing and reading lag.
  int ntpNow() => NtpClock.instance.now();

  /// Kick off NTP sync in background. Call once per room join/create.
  Future<void> _syncNtp() async {
    if (!NtpClock.instance.synced) {
      log('SyncService: starting NTP sync…', name: 'SyncService');
      await NtpClock.instance.sync();
    }
  }

  // ── Room management ───────────────────────────────────────────────────────

  static String _generateStamp() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Future<String> createRoom(SyncCallback onSync) async {
    await leaveRoom();
    await _syncNtp();

    _roomCode = _generateStamp();
    _role     = SyncRole.host;
    _roomRef  = FirebaseDatabase.instance.ref('syncRooms/$_roomCode');
    _onSync   = onSync;

    await _roomRef!.set({
      'host':         _deviceId,
      'ts':           ServerValue.timestamp,
      'members':      1,
      'roomOffsetMs': 0,
    });

    _startListeners();
    log('SyncService: created room $_roomCode', name: 'SyncService');
    return _roomCode!;
  }

  Future<bool> joinRoom(String stamp, SyncCallback onSync) async {
    await leaveRoom();
    await _syncNtp();

    final ref  = FirebaseDatabase.instance.ref('syncRooms/$stamp');
    final snap = await ref.get();
    if (!snap.exists) {
      log('SyncService: room $stamp not found', name: 'SyncService');
      return false;
    }

    _roomCode = stamp.toUpperCase();
    _role     = SyncRole.member;
    _roomRef  = ref;
    _onSync   = onSync;

    await _roomRef!.child('members').set(ServerValue.increment(1));
    _startListeners();

    log('SyncService: joined room $_roomCode', name: 'SyncService');
    return true;
  }

  void _startListeners() {
    // ── State listener (track / position / playing) ──
    _stateSub = _roomRef!.onValue.listen(
      (event) {
        final raw = event.snapshot.value;
        if (raw == null || raw is! Map) return;
        if (raw['trackId'] == null) return;
        // Ignore our own pushes.
        if ((raw['pushedBy'] as String?) == _deviceId) return;

        try {
          final packet = SyncPacket.fromMap(raw as Map<Object?, Object?>);
          _syncDriven = true;
          _onSync?.call(packet);
          // Reset flag after the async seek has had time to fire.
          Future.delayed(
            const Duration(milliseconds: 400),
            () => _syncDriven = false,
          );
        } catch (e) {
          log('SyncService: parse error $e', name: 'SyncService');
        }
      },
      onError: (Object e) =>
          log('SyncService: state listener error $e', name: 'SyncService'),
    );

    // ── Offset listener (shared slider) ──
    _offsetSub = _roomRef!.child('roomOffsetMs').onValue.listen(
      (event) {
        _roomOffsetMs = (event.snapshot.value as num?)?.toInt() ?? 0;
        log('SyncService: roomOffset=${_roomOffsetMs}ms', name: 'SyncService');
      },
    );
  }

  Future<void> leaveRoom() async {
    await _stateSub?.cancel();
    await _offsetSub?.cancel();
    _stateSub = null;
    _offsetSub = null;

    if (_role == SyncRole.member && _roomRef != null) {
      await _roomRef!
          .child('members')
          .set(ServerValue.increment(-1))
          .catchError((_) {});
    }
    if (_role == SyncRole.host && _roomRef != null) {
      await _roomRef!.remove().catchError((_) {});
    }

    _roomRef      = null;
    _roomCode     = null;
    _role         = SyncRole.none;
    _onSync       = null;
    _syncDriven   = false;
    _roomOffsetMs = 0;

    log('SyncService: left room', name: 'SyncService');
  }

  // ── Shared offset (anyone can call) ──────────────────────────────────────

  /// Write the new shared offset to RTDB. All members apply it immediately.
  Future<void> setRoomOffset(int offsetMs) async {
    if (!isActive || _roomRef == null) return;
    _roomOffsetMs = offsetMs;
    await _roomRef!
        .child('roomOffsetMs')
        .set(offsetMs)
        .catchError(
          (Object e) =>
              log('SyncService: offset write error $e', name: 'SyncService'),
        );
  }

  // ── Push (all members — collaborative) ───────────────────────────────────

  /// Push playback state. Any active member can call this.
  /// No-op when not in a room or when a received packet is being applied
  /// (prevents feedback loops).
  void pushState({
    required String trackId,
    required int positionMs,
    required bool playing,
    String trackTitle     = '',
    String trackArtist    = '',
    String trackThumbnail = '',
    int?   trackDurationMs,
  }) {
    if (!isActive || _roomRef == null) return;
    if (_syncDriven) return; // Don't echo incoming packets back.

    final data = <String, dynamic>{
      'trackId':        trackId,
      'positionMs':     positionMs,
      'playing':        playing,
      'ntpTs':          ntpNow(),   // NTP-corrected timestamp
      'pushedBy':       _deviceId,
      'trackTitle':     trackTitle,
      'trackArtist':    trackArtist,
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
