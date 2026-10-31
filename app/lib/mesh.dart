// Port of the send path of ../olight_mesh.py (Bluetooth Mesh network + access layer, Tuya vendor DP write).
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const company = 0x07D0;
const dstAllNodes = 0xFFFF;

Uint8List _aesEcb(Uint8List key, Uint8List block) {
  final e = AESEngine()..init(true, KeyParameter(key));
  return e.process(block);
}

Uint8List aesCmac(Uint8List key, Uint8List msg) {
  final c = CMac(AESEngine(), 128)..init(KeyParameter(key));
  return c.process(msg);
}

Uint8List _ccm(Uint8List key, Uint8List nonce, Uint8List data) {
  final c = CCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), 32, nonce, Uint8List(0)));
  return c.process(data); // ciphertext || 4-byte MIC
}

Uint8List _b(List<int> l) => Uint8List.fromList(l);
List<int> _be(int v, int n) => [for (var i = n - 1; i >= 0; i--) (v >> (8 * i)) & 0xFF];
List<int> _le(int v, int n) => _be(v, n).reversed.toList();

/// Application key identifier (6 bits).
int k4(Uint8List appKey) {
  final s1 = aesCmac(Uint8List(16), _b(utf8.encode('smk4')));
  final t = aesCmac(s1, appKey);
  return aesCmac(t, _b([...utf8.encode('id6'), 1]))[15] & 0x3F;
}

class MeshKeys {
  MeshKeys(this.nid, this.ivIndex, this.src, this.encKey, this.privKey, this.appKey, this.bulbs)
      : aid = k4(appKey);
  final int nid, ivIndex, src, aid;
  final Uint8List encKey, privKey, appKey;
  final Map<String, int?> bulbs; // BLE address -> unicast

  /// Same format as keys.json of the Python client.
  factory MeshKeys.fromJson(String text, {int src = 0x6101}) {
    final raw = jsonDecode(text) as Map<String, dynamic>;
    Uint8List key(String n) {
      final k = _b([for (var i = 0; i < 32; i += 2) int.parse((raw[n] as String).substring(i, i + 2), radix: 16)]);
      if ((raw[n] as String).length != 32) throw FormatException('$n must be 16 bytes');
      return k;
    }

    return MeshKeys(
      int.parse('${raw['nid']}'),
      int.parse('${raw['iv_index'] ?? 0}'),
      src, // default 0x6101: never reuse the CLI's SRC 0x6100: shared seq space
      key('enc_key'),
      key('priv_key'),
      key('app_key'),
      {
        for (final e in Map<String, dynamic>.from(raw['bulbs'] ?? {}).entries)
          e.key.toUpperCase(): e.value == null ? null : int.parse('${e.value}'),
      },
    );
  }
}

Uint8List accessEncrypt(MeshKeys k, int seq, int src, int dst, Uint8List access) {
  final nonce = _b([1, 0, ..._be(seq, 3), ..._be(src, 2), ..._be(dst, 2), ..._be(k.ivIndex, 4)]);
  return _b([(1 << 6) | k.aid, ..._ccm(k.appKey, nonce, access)]);
}

Uint8List buildNetworkPdu(MeshKeys k, int src, int dst, Uint8List transport, int seq, {int ttl = 8}) {
  final ctlTtl = ttl & 0x7F;
  final nonce = _b([0, ctlTtl, ..._be(seq, 3), ..._be(src, 2), 0, 0, ..._be(k.ivIndex, 4)]);
  final enc = _ccm(k.encKey, nonce, _b([..._be(dst, 2), ...transport]));
  final pecb = _aesEcb(k.privKey, _b([0, 0, 0, 0, 0, ..._be(k.ivIndex, 4), ...enc.sublist(0, 7)]));
  final hdr = [ctlTtl, ..._be(seq, 3), ..._be(src, 2)];
  return _b([((k.ivIndex & 1) << 7) | k.nid, for (var i = 0; i < 6; i++) hdr[i] ^ pecb[i], ...enc]);
}

/// Proxy PDU: SAR=complete, type=network PDU.
Uint8List proxyPdu(Uint8List net) => _b([0, ...net]);

// ---------- access messages ----------

Uint8List onoffSet(bool on, int tid) => _b([0x82, 0x02, on ? 1 : 0, tid]);

Uint8List lightnessSet(double pct, int tid) =>
    _b([0x82, 0x4C, ..._le((pct * 65535 / 100).round(), 2), tid]);

Uint8List hslSet(double lightnessPct, double hueDeg, double satPct, int tid) => _b([
      0x82, 0x76,
      ..._le((lightnessPct * 65535 / 100).round(), 2),
      ..._le((hueDeg * 65536 / 360).round() & 0xFFFF, 2),
      ..._le((satPct * 65535 / 100).round(), 2),
      tid,
    ]);

/// Vendor DP write 0xC9; workMode 0 = white, 1 = colour. items: pre-encoded [dp][type][value].
Uint8List dpWrite(int workMode, [List<int> items = const []]) =>
    _b([0xC9, ..._le(company, 2), workMode, ...items]);

Uint8List get modeWhite => dpWrite(0);
Uint8List get modeColour => dpWrite(1);
Uint8List get scene7 => dpWrite(1, [102, 0x04, 7]); // DP 102 enum 7 = custom colour (colour from HSL)

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
