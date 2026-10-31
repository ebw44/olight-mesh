import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mesh.dart';

final proxySvc = Guid('1828');
final dataOut = Guid('2ade'); // notify: replies from the bulb
final dataIn = Guid('2add'); // take it from the 0x1828 service: the provisioning service has the same UUIDs

/// One GATT proxy connection; every send uses a fresh, persisted sequence number.
class Bulb {
  Bulb(this.keys, this.device);
  final MeshKeys keys;
  final BluetoothDevice device;
  BluetoothCharacteristic? _in;
  StreamSubscription<List<int>>? _sub;
  Future<void> _queue = Future.value(); // serialises sends so sequence numbers never race
  final status = ValueNotifier<BulbStatus>(BulbStatus());
  int? _mode; // last work mode sent (0 white, 1 colour)
  // Controls shared by white and colour: brightness 0..100 %, colour hue / saturation.
  double brightness = 100, hue = 0, sat = 100;

  /// Unicast of the connected bulb from keys.json (matched by BLE address), else all nodes.
  /// Never another bulb's address: replies and commands must go to the bulb we are connected to.
  int? get unicast => keys.bulbs[device.remoteId.str.toUpperCase()] ?? _learned;
  bool get learned => keys.bulbs[device.remoteId.str.toUpperCase()] == null && _learned != null;
  int? _learned;
  Completer<int>? _firstReply;

  /// Bulb not listed in keys.json: ask all nodes once. The bulb we are connected to is the proxy,
  /// so its reply arrives first (the others are relayed ~0.5 s later); from then on address only it.
  Future<void> learnTarget() async {
    if (unicast != null) return;
    final c = _firstReply = Completer<int>();
    try {
      await send(onoffGet);
      _learned = await c.future.timeout(const Duration(seconds: 4));
      final s = status.value;
      s.sources
        ..clear()
        ..add(_learned!);
      status.value = s.copy();
    } on TimeoutException {
      // nobody answered: keep addressing all nodes
    } finally {
      _firstReply = null;
    }
  }
  int get dst => unicast ?? dstAllNodes;

  Future<void> connect() async {
    for (var i = 0; ; i++) {
      try {
        await device.connect(timeout: const Duration(seconds: 20));
        final svcs = await device.discoverServices();
        final svc = svcs.firstWhere((s) => s.uuid == proxySvc);
        _in = svc.characteristics.firstWhere((c) => c.uuid == dataIn);
        final out = svc.characteristics.firstWhere((c) => c.uuid == dataOut);
        await _sub?.cancel();
        _sub = out.onValueReceived.listen(_onNotify);
        await out.setNotifyValue(true);
        return;
      } catch (_) {
        if (i == 2) rethrow;
        await Future.delayed(const Duration(seconds: 6));
      }
    }
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    await device.disconnect();
  }

  void _onNotify(List<int> data) {
    final d = Uint8List.fromList(data);
    if (d.length < 2 || d[0] != 0) return; // only complete network PDUs (SAR 0, type 0)
    final net = parseNetworkPdu(keys, Uint8List.fromList(d.sublist(1)));
    if (net == null) return;
    final acc = accessDecrypt(keys, net);
    if (acc == null) return;
    final f = _firstReply;
    if (f != null && !f.isCompleted && unicast == null) f.complete(net.src);
    if (unicast != null && net.src != unicast) return; // reply from another bulb of the mesh
    final s = status.value;
    s.sources.add(net.src);
    if (s.apply(acc)) status.value = s.copy(); // new object so listeners rebuild
  }

  /// Ask the bulb for its state; answers arrive through [status].
  Future<void> refresh() async {
    for (final g in [onoffGet, lightnessGet, hslGet, vendorQuery]) {
      await send(g);
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<int> _nextSeq() async {
    final p = await SharedPreferences.getInstance();
    final seq = (p.getInt('seq') ?? 0x100000) + 1;
    await p.setInt('seq', seq); // persisted before sending so a restart never reuses one
    return seq;
  }

  Future<void> send(Uint8List access) {
    final r = _queue.then((_) => _send(access));
    _queue = r.catchError((_) {});
    return r;
  }

  Future<void> _send(Uint8List access) async {
    final seq = await _nextSeq();
    final net = buildNetworkPdu(keys, keys.src, dst, accessEncrypt(keys, seq, keys.src, dst, access), seq);
    await _in!.write(proxyPdu(net), withoutResponse: true);
  }

  Future<void> setOn(bool on) => send(onoffSet(on, 0));

  int get _currentMode => _mode ?? status.value.workMode ?? 0;

  /// Switch work mode if needed; a slow bulb needs a moment before it takes the next command.
  Future<void> _ensureMode(int mode) async {
    if (_currentMode == mode && _mode != null) return;
    await send(mode == 1 ? scene7 : modeWhite);
    _mode = mode;
    await Future.delayed(const Duration(milliseconds: 400));
  }

  Future<void> _sendColour() => send(hslSet(brightness.clamp(1.0, 100.0) / 2, hue, sat, 0)); // L 50 % = full colour

  /// Brightness applies to whatever is showing: white level in white mode, colour intensity in colour mode.
  Future<void> setBrightness(double pct) async {
    brightness = pct;
    if (_currentMode == 1) {
      await _sendColour();
    } else {
      await _ensureMode(0);
      await send(lightnessSet(pct, 0));
    }
  }

  Future<void> setColour(double h, double s) async {
    hue = h;
    sat = s;
    await _ensureMode(1);
    await _sendColour();
  }

  Future<void> setWhite() async {
    await _ensureMode(0);
    await send(lightnessSet(brightness, 0));
  }
}
