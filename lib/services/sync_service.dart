import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:math' hide log;
import 'dart:typed_data';

import 'package:firebase_database/firebase_database.dart';
import 'package:path_provider/path_provider.dart';

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

  int  now()        => DateTime.now().millisecondsSinceEpoch + _offsetMs;
  bool get synced   => _synced;

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

// ─── Device name ─────────────────────────────────────────────────────────────

class DeviceNamer {
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
    try {
      final dir  = await getApplicationSupportDirectory();
      final file = File('${dir.path}/sync_device_name.txt');
      if (await file.exists()) return (await file.readAsString()).trim();
      final rng  = Random.secure();
      final name = '${_adj[rng.nextInt(_adj.length)]} ${_noun[rng.nextInt(_noun.length)]}';
      await file.writeAsString(name);
      return name;
    } catch (_) {
      final rng = Random.secure();
      return '${_adj[rng.nextInt(_adj.length)]} ${_noun[rng.nextInt(_noun.length)]}';
    }
  }
}

// ─── Device ID (persistent across sessions) ───────────────────────────────────

class DeviceIdStore {
  static Future<String> get() async {
    try {
      final dir  = await getApplicationSupportDirectory();
      final file = File('${dir.path}/sync_device_id.txt');
      if (await file.exists()) return (await file.readAsString()).trim();
      const c   = 'abcdefghijklmnopqrstuvwxyz0123456789';
      final rng = Random.secure();
      final id  = List.generate(12, (_) => c[rng.nextInt(c.length)]).join();
      await file.writeAsString(id);
      return id;
    } catch (_) {
      const c   = 'abcdefghijklmnopqrstuvwxyz0123456789';
      final rng = Random.secure();
      return List.generate(12, (_) => c[rng.nextInt(c.length)]).join();
    }
  }
}

// ─── Saved group model ────────────────────────────────────────────────────────

class SavedGroup {
  final String code;
  final String name;

  const SavedGroup({required this.code, required this.name});

  Map<String, dynamic> toJson() => {'code': code, 'name': name};

  factory SavedGroup.fromJson(Map<String, dynamic> j) =>
      SavedGroup(code: j['code'] as String, name: j['name'] as String);
}

// ─── Local group store ────────────────────────────────────────────────────────

class GroupStore {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/sync_groups.json');
  }

  static Future<List<SavedGroup>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final raw = jsonDecode(await f.readAsString()) as List;
      return raw
          .map((e) => SavedGroup.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _write(List<SavedGroup> groups) async {
    final f = await _file();
    await f.writeAsString(
        jsonEncode(groups.map((g) => g.toJson()).toList()));
  }

  static Future<void> add(SavedGroup group) async {
    final groups = await load();
    if (groups.any((g) => g.code == group.code)) return;
    groups.add(group);
    await _write(groups);
  }

  static Future<void> remove(String code) async {
    final groups = await load();
    groups.removeWhere((g) => g.code == code);
    await _write(groups);
  }
}

// ─── Models ───────────────────────────────────────────────────────────────────

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

  /// How far ahead (ms) the guest should schedule play() from now.
  /// 0 = apply immediately (drift correction). >0 = scheduled-play event.
  final int scheduleAheadMs;

  const SyncPacket({
    required this.trackId,
    required this.positionMs,
    required this.playing,
    required this.ntpTs,
    this.scheduleAheadMs = 0,
    this.pushedBy        = '',
    this.trackTitle      = '',
    this.trackArtist     = '',
    this.trackThumbnail  = '',
    this.trackDurationMs,
  });

  factory SyncPacket.fromMap(Map<Object?, Object?> map) => SyncPacket(
    trackId:         (map['trackId']         as String?) ?? '',
    positionMs:      (map['positionMs']      as num?)?.toInt() ?? 0,
    playing:         (map['playing']         as bool?)  ?? false,
    ntpTs:           (map['ntpTs']           as num?)?.toInt() ??
                     DateTime.now().millisecondsSinceEpoch,
    scheduleAheadMs: (map['scheduleAheadMs'] as num?)?.toInt() ?? 0,
    pushedBy:        (map['pushedBy']        as String?) ?? '',
    trackTitle:      (map['trackTitle']      as String?) ?? '',
    trackArtist:     (map['trackArtist']     as String?) ?? '',
    trackThumbnail:  (map['trackThumbnail']  as String?) ?? '',
    trackDurationMs: (map['trackDurationMs'] as num?)?.toInt(),
  );
}

/// Online device entry — from sessions/{code}/online/{deviceId}.
class SyncDevice {
  final String deviceId;
  final String name;
  final int    offsetMs;

  const SyncDevice({
    required this.deviceId,
    required this.name,
    required this.offsetMs,
  });

  factory SyncDevice.fromEntry(String id, Map<Object?, Object?> map) => SyncDevice(
    deviceId: id,
    name:     (map['name']     as String?) ?? 'Unknown',
    offsetMs: (map['offsetMs'] as num?)?.toInt() ?? 0,
  );
}

// ─── Role ─────────────────────────────────────────────────────────────────────

enum SyncRole { none, connected }

// ─── Service ──────────────────────────────────────────────────────────────────
//
// RTDB layout:
//
//  groups/{code}/
//    name: "AJ Squad"
//    roster/
//      {deviceId}: "Swift Mango"   ← permanent, survives disconnects
//
//  sessions/{code}/
//    state/
//      trackId, positionMs, playing, ntpTs, pushedBy, trackTitle, …
//    online/
//      {deviceId}/
//        name:     "Swift Mango"
//        offsetMs: 0              ← onDisconnect removes entire entry
//
// Anyone online can push state. No host concept.

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  // Resolved once during _init()
  String _deviceId   = '';
  String _deviceName = 'Unknown';
  bool   _initialized = false;

  SyncRole _role       = SyncRole.none;
  String?  _activeCode;
  DatabaseReference? _sessionRef;    // sessions/{code}

  SyncCallback?   _onSync;
  SeekCallback?   _seekCallback;
  PositionGetter? _positionGetter;

  StreamSubscription<DatabaseEvent>? _stateSub;
  StreamSubscription<DatabaseEvent>? _offsetSub;

  // _syncDriven:   suppress pushState while applying incoming room state / on resume
  // _offsetDriven: suppress pushState while seeking due to offset adjustment
  bool _syncDriven   = false;
  bool _offsetDriven = false;
  int  _myOffsetMs   = 0;

  // ── Getters ───────────────────────────────────────────────────────────────

  SyncRole get role        => _role;
  String?  get activeCode  => _activeCode;
  bool     get isActive    => _role == SyncRole.connected;
  String   get deviceId    => _deviceId;
  String   get deviceName  => _deviceName;
  int      get myOffsetMs  => _myOffsetMs;
  int      ntpNow()        => NtpClock.instance.now();

  /// Live list of online devices for the current session.
  Stream<List<SyncDevice>>? get onlineStream {
    if (_sessionRef == null) return null;
    return _sessionRef!.child('online').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw == null || raw is! Map) return <SyncDevice>[];
      return raw.entries
          .map((e) => SyncDevice.fromEntry(
                e.key as String,
                e.value as Map<Object?, Object?>,
              ))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    });
  }

  /// Online member count for any group code — used in the group list UI.
  /// Creates a transient listener; caller cancels via StreamSubscription.
  Stream<int> onlineCountStream(String code) {
    return FirebaseDatabase.instance
        .ref('sessions/$code/online')
        .onValue
        .map((event) {
          final raw = event.snapshot.value;
          if (raw == null || raw is! Map) return 0;
          return (raw as Map).length;
        });
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    if (_initialized) return;
    _deviceId   = await DeviceIdStore.get();
    _deviceName = await DeviceNamer.get();
    if (!NtpClock.instance.synced) await NtpClock.instance.sync();
    _initialized = true;
  }

  // ── Group operations ──────────────────────────────────────────────────────

  static String _generateCode() {
    const c = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(6, (_) => c[r.nextInt(c.length)]).join();
  }

  /// Creates a new group in RTDB, saves it locally. Returns the new group.
  Future<SavedGroup> createGroup(String name) async {
    await _init();
    final code = _generateCode();
    final ref  = FirebaseDatabase.instance.ref('groups/$code');
    await ref.set({'name': name});
    await ref.child('roster/$_deviceId').set(_deviceName);
    final group = SavedGroup(code: code, name: name);
    await GroupStore.add(group);
    log('SyncService: created group $code "$name"', name: 'SyncService');
    return group;
  }

  /// Joins an existing group. Returns the group on success, null if not found.
  Future<SavedGroup?> joinGroup(String code) async {
    await _init();
    final upper = code.toUpperCase();
    final ref   = FirebaseDatabase.instance.ref('groups/$upper');
    final snap  = await ref.get();
    if (!snap.exists) return null;

    final name = (snap.child('name').value as String?) ?? upper;
    await ref.child('roster/$_deviceId').set(_deviceName);
    final group = SavedGroup(code: upper, name: name);
    await GroupStore.add(group);
    log('SyncService: joined group $upper "$name"', name: 'SyncService');
    return group;
  }

  /// Permanently removes self from group roster and local storage.
  /// Disconnects session if currently connected to this group.
  Future<void> leaveGroup(String code) async {
    await _init();
    if (_activeCode == code) await disconnectSession();
    await FirebaseDatabase.instance
        .ref('groups/$code/roster/$_deviceId')
        .remove()
        .catchError((_) {});
    await GroupStore.remove(code);
    log('SyncService: left group $code', name: 'SyncService');
  }

  // ── Session operations ────────────────────────────────────────────────────

  /// Connect to a session (write online presence, start listeners).
  /// Idempotent — calling while already connected to the same code is a no-op.
  Future<void> connectSession(
    String code, {
    required SyncCallback   onSync,
    required SeekCallback   onSeek,
    required PositionGetter getPosition,
  }) async {
    if (_activeCode == code && _role == SyncRole.connected) return;
    await disconnectSession();
    await _init();

    _activeCode     = code;
    _role           = SyncRole.connected;
    _sessionRef     = FirebaseDatabase.instance.ref('sessions/$code');
    _onSync         = onSync;
    _seekCallback   = onSeek;
    _positionGetter = getPosition;
    _myOffsetMs     = 0;

    // Write online presence
    await _sessionRef!.child('online/$_deviceId').set({
      'name':     _deviceName,
      'offsetMs': 0,
    });
    // Auto-remove entire online entry on disconnect — ghost problem is
    // structurally impossible since Firebase handles cleanup even on crash.
    await _sessionRef!.child('online/$_deviceId').onDisconnect().remove();

    _startListeners();
    log('SyncService: connected to session $code as "$_deviceName"', name: 'SyncService');
  }

  /// Disconnect from current session (stay in the group).
  Future<void> disconnectSession() async {
    await _stateSub?.cancel();
    await _offsetSub?.cancel();
    _stateSub  = null;
    _offsetSub = null;

    // Cancel Firebase's auto-remove hook, then remove manually.
    await _sessionRef
        ?.child('online/$_deviceId')
        .onDisconnect()
        .cancel()
        .catchError((_) {});
    await _sessionRef
        ?.child('online/$_deviceId')
        .remove()
        .catchError((_) {});

    _sessionRef     = null;
    _activeCode     = null;
    _role           = SyncRole.none;
    _onSync         = null;
    _seekCallback   = null;
    _positionGetter = null;
    _syncDriven     = false;
    _offsetDriven   = false;
    _myOffsetMs     = 0;

    log('SyncService: disconnected from session', name: 'SyncService');
  }

  void _startListeners() {
    // ── State listener ───────────────────────────────────────────────────────
    _stateSub = _sessionRef!.child('state').onValue.listen((event) {
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

    // ── Offset listener (Bug 1 fix) ──────────────────────────────────────────
    // Listen directly on our own offsetMs field — no snapshot-behind lag from
    // listening on the parent 'online' node.
    _offsetSub = _sessionRef!
        .child('online/$_deviceId/offsetMs')
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) return;

      final newOffset = (raw as num).toInt();
      if (newOffset == _myOffsetMs) return;

      final delta  = newOffset - _myOffsetMs;
      _myOffsetMs  = newOffset;

      final current = _positionGetter?.call() ?? Duration.zero;
      final adjusted = Duration(
        milliseconds: (current.inMilliseconds + delta).clamp(0, 9999999),
      );

      // Bug 1b fix: flag the seek so pushState ignores it.
      // Offset correction is personal — not a room event.
      _offsetDriven = true;
      _seekCallback?.call(adjusted);
      Future.delayed(const Duration(milliseconds: 400), () => _offsetDriven = false);

      log('SyncService: offset → ${newOffset}ms, seeked by ${delta}ms',
          name: 'SyncService');
    });
  }

  // ── Resync on resume (Bug 2 fix) ──────────────────────────────────────────

  /// Call this before resuming playback after an audio interruption.
  /// Fetches current room state from RTDB and applies it, while blocking
  /// the plugin reinitialization from overwriting the room with stale data.
  Future<void> resyncOnResume() async {
    if (!isActive || _sessionRef == null) return;

    // Block pushState for 2 s during plugin reinitialization.
    _syncDriven = true;
    Future.delayed(const Duration(seconds: 2), () => _syncDriven = false);

    try {
      final snap = await _sessionRef!.child('state').get();
      if (!snap.exists || snap.value == null) return;
      final raw = snap.value;
      if (raw is! Map) return;
      final packet = SyncPacket.fromMap(raw as Map<Object?, Object?>);
      _onSync?.call(packet);
      log('SyncService: resynced on resume', name: 'SyncService');
    } catch (e) {
      log('SyncService: resync failed: $e', name: 'SyncService');
    }
  }

  // ── Push state ────────────────────────────────────────────────────────────

  /// [scheduleAheadMs] > 0 tells guests to schedule play() that many ms
  /// from now rather than seeking immediately. Use for discrete events
  /// (explicit seek, play/pause, track change). Leave 0 for drift correction.
  void pushState({
    required String trackId,
    required int    positionMs,
    required bool   playing,
    int    scheduleAheadMs = 0,
    String trackTitle      = '',
    String trackArtist     = '',
    String trackThumbnail  = '',
    int?   trackDurationMs,
  }) {
    // Don't push while applying incoming state, during offset-driven seek,
    // or during post-interruption plugin reinitialization.
    if (!isActive || _sessionRef == null || _syncDriven || _offsetDriven) return;

    _sessionRef!.child('state').update({
      'trackId':        trackId,
      'positionMs':     positionMs,
      'playing':        playing,
      'ntpTs':          ntpNow(),
      'scheduleAheadMs': scheduleAheadMs,
      'pushedBy':       _deviceId,
      'trackTitle':     trackTitle,
      'trackArtist':    trackArtist,
      'trackThumbnail': trackThumbnail,
      if (trackDurationMs != null) 'trackDurationMs': trackDurationMs,
    }).catchError((Object e) =>
        log('SyncService: push error $e', name: 'SyncService'));
  }

  // ── Offset ────────────────────────────────────────────────────────────────

  Future<void> setDeviceOffset(String targetDeviceId, int offsetMs) async {
    if (!isActive || _sessionRef == null) return;
    await _sessionRef!
        .child('online/$targetDeviceId/offsetMs')
        .set(offsetMs)
        .catchError((Object e) =>
            log('SyncService: offset write error $e', name: 'SyncService'));
  }
}
