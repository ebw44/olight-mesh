import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mesh.dart';

final proxySvc = Guid('1828');
final dataIn = Guid('2add'); // take it from the 0x1828 service: the provisioning service has the same UUIDs

/// One GATT proxy connection; every send uses a fresh, persisted sequence number.
class Bulb {
  Bulb(this.keys, this.device);
  final MeshKeys keys;
  final BluetoothDevice device;
  BluetoothCharacteristic? _in;
  int? _mode; // last work mode sent (0 white, 1 colour) to avoid resending the switch

  int get dst => keys.bulbs.values.firstWhere((u) => u != null, orElse: () => null) ?? dstAllNodes;

  Future<void> connect() async {
    for (var i = 0; ; i++) {
      try {
        await device.connect(timeout: const Duration(seconds: 20));
        final svcs = await device.discoverServices();
        _in = svcs.firstWhere((s) => s.uuid == proxySvc).characteristics.firstWhere((c) => c.uuid == dataIn);
        return;
      } catch (_) {
        if (i == 2) rethrow;
        await Future.delayed(const Duration(seconds: 6));
      }
    }
  }

  Future<void> disconnect() => device.disconnect();

  Future<int> _nextSeq() async {
    final p = await SharedPreferences.getInstance();
    final seq = (p.getInt('seq') ?? 0x100000) + 1;
    await p.setInt('seq', seq); // persisted before sending so a restart never reuses one
    return seq;
  }

  Future<void> send(Uint8List access) async {
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
