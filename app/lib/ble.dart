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
  int? _mode; // last work mode sent (0 white, 1 colour) to avoid resending the switch

  int get dst => keys.bulbs.values.firstWhere((u) => u != null, orElse: () => null) ?? dstAllNodes;

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
    final s = status.value;
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

  Future<void> setBrightness(double pct) async {
    if (_mode != 0) await send(modeWhite);
    _mode = 0;
    await send(lightnessSet(pct, 0));
  }

  Future<void> setColour(double hue, double sat) async {
    if (_mode != 1) await send(scene7);
    _mode = 1;
    await send(hslSet(50, hue, sat, 0)); // lightness 50 % = full colour
  }
}
