import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:math' hide log;
import 'dart:typed_data';

import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef SyncCallback   = void Function(SyncPacket packet);
typedef SeekCallback   = void Function(Duration position);
typedef PositionGetter = Duration Function();

// ─── NTP Clock ───────────────────────────────────────────────────────────────

class NtpClock {
  NtpClock._();
  static final NtpClock instance = NtpClock._();

  static const _servers   = ['pool.ntp.org', 'time.google.com'];
  static const _port      = 123;
  static const _delta     = 2208988800;
  static const _rounds    = 5;
  static const _maxRttMs  = 500;
  static const _timeoutMs = 2000;

  int  _offsetMs = 0;
  bool _synced   = false;

  int  now()    => DateTime.now().millisecondsSinceEpoch + _offsetMs;
  bool get synced => _synced;

  Future<void> sync() async {
    for (final server in _servers) {
      final offset = await _tryServer(server);
      if (offset != null) {
        _offsetMs = offset;
        _synced   = true;
        log('NtpClock: synced via $server offset=${_offsetMs}ms', name: 'NtpClock');
        return;
      }
    }
    _synced = true;
    log('NtpClock: all servers failed, using local clock', name: 'NtpClock');
  }

  Future<int?> _tryServer(String server) async {
    int  bestRtt    = _maxRttMs + 1;
    int  bestOffset = 0;
    bool got        = false;

    List<InternetAddress> addrs;
    try { addrs = await InternetAddress.lookup(server); }
    catch (_) { return null; }
    final addr = addrs.first;

    for (int i = 0; i < _rounds; i++) {
      RawDatagramSocket? sock;
      try {
        sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        sock.readEventsEnabled = true;
        final req = Uint8List(48)..first = 0x1B;
        final t1  = DateTime.now().millisecondsSinceEpoch;
        sock.send(req, addr, _port);

        Datagram? dg;
        final deadline = t1 + _timeoutMs;
        await for (final ev in sock) {
          if (ev == RawSocketEvent.read) { dg = sock.receive(); break; }
          if (DateTime.now().millisecondsSinceEpoch > deadline) break;
        }
        final t4 = DateTime.now().millisecondsSinceEpoch;
        if (dg == null || dg.data.length < 48) continue;

        final data = dg.data;
        int sec = 0;
        for (int b = 32; b < 36; b++) sec = (sec << 8) | (data[b] & 0xFF);
        final t2     = (sec - _delta) * 1000;
        final rtt    = t4 - t1;
        final offset = t2 - (t1 + t4) ~/ 2;

        if (rtt < bestRtt && rtt < _maxRttMs) {
          bestRtt = rtt; bestOffset = offset; got = true;
        }
      } catch (e) {
        log('NtpClock: round $i failed: $e', name: 'NtpClock');
      } finally {
        sock?.close();
      }
      if (i < _rounds - 1) await Future.delayed(const Duration(milliseconds: 30));
    }
    return got ? bestOffset : null;
  }
}

// ─── Device name generator ───────────────────────────────────────────────────
//
// Generates a persistent two-word fun name (e.g. "Swift Mango").
// Stored in SharedPreferences so the same device always has the same name.

class DeviceNamer {
  static const _key = 'sync_device_name';

  static const _adj = [
    'Swift', 'Bold', 'Calm', 'Dusk', 'Epic', 'Fawn',
    'Gold', 'Hazy', 'Icy', 'Jade', 'Keen', 'Lush',
    'Mint', 'Nova', 'Onyx', 'Plum', 'Rosy', 'Sage',
    'Teal', 'Umber', 'Vivid', 'Wild', 'Zeal', 'Amber',
  ];

  static const _noun = [
    'Mango', 'Pixel', 'Comet', 'River', 'Storm', 'Flare',
    'Prism', 'Echo', 'Blaze', 'Drift', 'Pulse', 'Spark',
    'Wave', 'Frost', 'Bloom', 'Dune', 'Glow', 'Haze',
    'Isle', 'Knot', 'Lark', 'Moss', 'Nook', 'Opal',
  ];

  static Future<String> get() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null) return saved;
    final rng  = Random.secure();
    final name = '${_adj[rng.nextInt(_adj.length)]} ${_noun[rng.nextInt(_noun.length)]}';
    await prefs.setString(_key, name);
    return name;
  }
}

// ─── Models ──────────────────────────────────────────────────────────────────

class SyncPacket {
  final String trackId;
  final int    positionMs;
  final bool   playing;
  final int    ntpTs;
  final String pushedBy;
  final String trackTitle;
  final String trackArtist;
  final String trackThumbnail;
  final int?   trackDurationMs;

  const SyncPacket({
    required this.trackId,
    required this.positionMs,
    required this.playing,
    required this.ntpTs,
    this.pushedBy       = '',
    this.trackTitle     = '',
    this.trackArtist    = '',
    this.trackThumbnail = '',
    this.trackDurationMs,
  });

  factory SyncPacket.fromMap(Map<Object?, Object?> map) => SyncPacket(
    trackId:         (map['trackId']        as String?) ?? '',
    positionMs:      (map['positionMs']     as num?)?.toInt() ?? 0,
    playing:         (map['playing']        as bool?) ?? false,
    ntpTs:           (map['ntpTs']          as num?)?.toInt() ??
                     DateTime.now().millisecondsSinceEpoch,
    pushedBy:        (map['pushedBy']       as String?) ?? '',
    trackTitle:      (map['trackTitle']     as String?) ?? '',
    trackArtist:     (map['trackArtist']    as String?) ?? '',
    trackThumbnail:  (map['trackThumbnail'] as String?) ?? '',
    trackDurationMs: (map['trackDurationMs'] as num?)?.toInt(),
  );
}

/// One entry in the devices list.
class SyncDevice {
  final String deviceId;
  final String name;
  final int    offsetMs;
  final int    lastSeenMs;

  const SyncDevice({
    required this.deviceId,
    required this.name,
    required this.offsetMs,
    required this.lastSeenMs,
  });

  factory SyncDevice.fromEntry(String id, Map<Object?, Object?> map) => SyncDevice(
    deviceId:   id,
    name:       (map['name']       as String?) ?? 'Unknown',
    offsetMs:   (map['offsetMs']   as num?)?.toInt() ?? 0,
    lastSeenMs: (map['lastSeenMs'] as num?)?.toInt() ?? 0,
  );
}

// ─── Role ────────────────────────────────────────────────────────────────────

enum SyncRole { none, host, member }

// ─── Service ─────────────────────────────────────────────────────────────────
//
// RTDB layout:
//
//  syncRooms/{stamp}/
//    host: deviceId
//    state/
//      trackId, positionMs, playing, ntpTs, pushedBy, trackTitle, …
//    devices/
//      {deviceId}/
//        name:       "Swift Mango"
//        offsetMs:   -200          ← writable by ANYONE
//        lastSeenMs: 1234567890

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  // Stable per-session device ID.
  final String _deviceId = _makeId();
  static String _makeId() {
    const c = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(12, (_) => c[r.nextInt(c.length)]).join();
  }

  String _deviceName = 'Unknown';
  String get deviceId   => _deviceId;
  String get deviceName => _deviceName;

  SyncRole _role    = SyncRole.none;
  String?  _roomCode;
  DatabaseReference? _roomRef;

  // Callbacks set by the sheet when joining/creating.
  SyncCallback?   _onSync;
  SeekCallback?   _seekCallback;
  PositionGetter? _positionGetter;

  StreamSubscription<DatabaseEvent>? _stateSub;
  StreamSubscription<DatabaseEvent>? _devicesSub;

  bool _syncDriven  = false;
  int  _myOffsetMs  = 0;

  // ── Getters ───────────────────────────────────────────────────────────────

  SyncRole get role     => _role;
  String?  get roomCode => _roomCode;
  bool     get isActive => _role != SyncRole.none;
  bool     get isHost   => _role == SyncRole.host;
  int      get myOffsetMs => _myOffsetMs;
  int      ntpNow()    => NtpClock.instance.now();

  /// Stream of all devices in the room — use in UI.
  Stream<List<SyncDevice>>? get devicesStream {
    if (_roomRef == null) return null;
    return _roomRef!.child('devices').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw == null || raw is! Map) return [];
      return raw.entries
          .map((e) => SyncDevice.fromEntry(
                e.key as String,
                e.value as Map<Object?, Object?>,
              ))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    });
  }

  // ── NTP ───────────────────────────────────────────────────────────────────

  Future<void> _syncNtp() async {
    if (!NtpClock.instance.synced) await NtpClock.instance.sync();
  }

  // ── Room management ───────────────────────────────────────────────────────

  static String _generateStamp() {
    const c = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(6, (_) => c[r.nextInt(c.length)]).join();
  }

  Future<String> createRoom({
    required SyncCallback   onSync,
    required SeekCallback   onSeek,
    required PositionGetter getPosition,
  }) async {
    await leaveRoom();
    await _syncNtp();
    _deviceName = await DeviceNamer.get();

    _roomCode       = _generateStamp();
    _role           = SyncRole.host;
    _roomRef        = FirebaseDatabase.instance.ref('syncRooms/$_roomCode');
    _onSync         = onSync;
    _seekCallback   = onSeek;
    _positionGetter = getPosition;
    _myOffsetMs     = 0;

    await _roomRef!.set({'host': _deviceId, 'ts': ServerValue.timestamp});
    await _registerDevice();
    _startListeners();

    log('SyncService: created room $_roomCode as "$_deviceName"', name: 'SyncService');
    return _roomCode!;
  }

  Future<bool> joinRoom({
    required String         stamp,
    required SyncCallback   onSync,
    required SeekCallback   onSeek,
    required PositionGetter getPosition,
  }) async {
    await leaveRoom();
    await _syncNtp();
    _deviceName = await DeviceNamer.get();

    final ref  = FirebaseDatabase.instance.ref('syncRooms/$stamp');
    final snap = await ref.get();
    if (!snap.exists) return false;

    _roomCode       = stamp.toUpperCase();
    _role           = SyncRole.member;
    _roomRef        = ref;
    _onSync         = onSync;
    _seekCallback   = onSeek;
    _positionGetter = getPosition;
    _myOffsetMs     = 0;

    await _registerDevice();
    _startListeners();

    log('SyncService: joined room $_roomCode as "$_deviceName"', name: 'SyncService');
    return true;
  }

  Future<void> _registerDevice() async {
    await _roomRef!.child('devices/$_deviceId').set({
      'name':       _deviceName,
      'offsetMs':   0,
      'lastSeenMs': ServerValue.timestamp,
    });
    // Remove our device entry when we disconnect (Firebase onDisconnect).
    await _roomRef!
        .child('devices/$_deviceId')
        .onDisconnect()
        .remove();
  }

  void _startListeners() {
    // ── State (track / position / playing) ──────────────────────────────────
    _stateSub = _roomRef!.child('state').onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw == null || raw is! Map) return;
      if ((raw['pushedBy'] as String?) == _deviceId) return; // own echo

      try {
        final packet = SyncPacket.fromMap(raw as Map<Object?, Object?>);
        _syncDriven = true;
        _onSync?.call(packet);
        Future.delayed(const Duration(milliseconds: 400), () => _syncDriven = false);
      } catch (e) {
        log('SyncService: state parse error $e', name: 'SyncService');
      }
    });

    // ── Devices (offset changes for all devices) ─────────────────────────────
    _devicesSub = _roomRef!.child('devices').onChildChanged.listen((event) {
      final changedId = event.snapshot.key;
      if (changedId != _deviceId) return; // only care about our own offset

      final raw = event.snapshot.value;
      if (raw == null || raw is! Map) return;

      final newOffset = (raw['offsetMs'] as num?)?.toInt() ?? 0;
      final delta     = newOffset - _myOffsetMs;
      _myOffsetMs     = newOffset;

      // Immediately seek by the delta — no need to wait for next packet.
      final current = _positionGetter?.call() ?? Duration.zero;
      final adjusted = Duration(
        milliseconds: (current.inMilliseconds + delta).clamp(0, 9999999),
      );
      _seekCallback?.call(adjusted);

      log('SyncService: own offset changed to ${newOffset}ms, seeked by ${delta}ms',
          name: 'SyncService');
    });
  }

  Future<void> leaveRoom() async {
    await _stateSub?.cancel();
    await _devicesSub?.cancel();
    _stateSub  = null;
    _devicesSub = null;

    // Remove our device entry.
    await _roomRef?.child('devices/$_deviceId').remove().catchError((_) {});

    // Host cleans up the whole room.
    if (_role == SyncRole.host) {
      await _roomRef?.remove().catchError((_) {});
    }

    _roomRef        = null;
    _roomCode       = null;
    _role           = SyncRole.none;
    _onSync         = null;
    _seekCallback   = null;
    _positionGetter = null;
    _syncDriven     = false;
    _myOffsetMs     = 0;

    log('SyncService: left room', name: 'SyncService');
  }

  // ── Per-device offset (anyone writes anyone's) ────────────────────────────

  /// Write [offsetMs] for [targetDeviceId] to RTDB.
  /// If it's our own device, the _devicesSub listener applies it immediately.
  Future<void> setDeviceOffset(String targetDeviceId, int offsetMs) async {
    if (!isActive || _roomRef == null) return;
    await _roomRef!
        .child('devices/$targetDeviceId/offsetMs')
        .set(offsetMs)
        .catchError((Object e) =>
            log('SyncService: offset write error $e', name: 'SyncService'));
  }

  // ── Push playback state ───────────────────────────────────────────────────

  void pushState({
    required String trackId,
    required int    positionMs,
    required bool   playing,
    String trackTitle     = '',
    String trackArtist    = '',
    String trackThumbnail = '',
    int?   trackDurationMs,
  }) {
    if (!isActive || _roomRef == null || _syncDriven) return;

    _roomRef!.child('state').update({
      'trackId':        trackId,
      'positionMs':     positionMs,
      'playing':        playing,
      'ntpTs':          ntpNow(),
      'pushedBy':       _deviceId,
      'trackTitle':     trackTitle,
      'trackArtist':    trackArtist,
      'trackThumbnail': trackThumbnail,
      if (trackDurationMs != null) 'trackDurationMs': trackDurationMs,
    }).catchError((Object e) =>
        log('SyncService: push error $e', name: 'SyncService'));
  }
}
