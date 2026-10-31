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

Uint8List _ccm(Uint8List key, Uint8List nonce, Uint8List data, [int macBits = 32]) {
  final c = CCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), macBits, nonce, Uint8List(0)));
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

// ---------- receive path ----------

Uint8List? _ccmDecrypt(Uint8List key, Uint8List nonce, Uint8List data) {
  final c = CCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(key), 32, nonce, Uint8List(0)));
  try {
    return c.process(data);
  } catch (_) {
    return null; // MIC mismatch
  }
}

class NetPdu {
  NetPdu(this.ctl, this.ttl, this.seq, this.src, this.dst, this.transport);
  final bool ctl;
  final int ttl, seq, src, dst;
  final Uint8List transport;
}

/// Mirror of parse_network_pdu: null if NID / NetMIC do not match. [pdu] excludes the proxy header byte.
NetPdu? parseNetworkPdu(MeshKeys k, Uint8List pdu) {
  if (pdu.length < 13 || (pdu[0] & 0x7F) != k.nid) return null;
  final enc = Uint8List.fromList(pdu.sublist(7));
  final pecb = _aesEcb(k.privKey, _b([0, 0, 0, 0, 0, ..._be(k.ivIndex, 4), ...enc.sublist(0, 7)]));
  final hdr = [for (var i = 0; i < 6; i++) pdu[1 + i] ^ pecb[i]];
  final ctlTtl = hdr[0];
  final seq = (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
  final src = (hdr[4] << 8) | hdr[5];
  if (ctlTtl >> 7 != 0) return null; // control messages: not handled
  final nonce = _b([0, ctlTtl, ..._be(seq, 3), ..._be(src, 2), 0, 0, ..._be(k.ivIndex, 4)]);
  final clear = _ccmDecrypt(k.encKey, nonce, enc);
  if (clear == null || clear.length < 2) return null;
  return NetPdu(false, ctlTtl & 0x7F, seq, src, (clear[0] << 8) | clear[1], Uint8List.fromList(clear.sublist(2)));
}

/// App-key access payload of an unsegmented message, or null.
Uint8List? accessDecrypt(MeshKeys k, NetPdu n) {
  final t = n.transport;
  if (t.isEmpty || t[0] & 0x80 != 0) return null; // segmented
  if ((t[0] >> 6) & 1 == 0) return null; // device-key message
  if ((t[0] & 0x3F) != k.aid) return null;
  final nonce = _b([1, 0, ..._be(n.seq, 3), ..._be(n.src, 2), ..._be(n.dst, 2), ..._be(k.ivIndex, 4)]);
  return _ccmDecrypt(k.appKey, nonce, Uint8List.fromList(t.sublist(1)));
}

// Get messages (read-only)
Uint8List get onoffGet => _b([0x82, 0x01]);
Uint8List get lightnessGet => _b([0x82, 0x4B]);
Uint8List get hslGet => _b([0x82, 0x6D]);
Uint8List get vendorQuery => _b([0xCC, ..._le(company, 2)]);

/// Last known state of the bulb, merged from every status / report received.
class BulbStatus {
  bool? on;
  double? lightness; // % from Lightness / HSL status
  double? hue, sat; // degrees / % from HSL status
  int? workMode; // 0 white, 1 colour
  final Map<int, int> dps = {}; // Tuya data points from vendor reports
  DateTime? updated;
  final Set<int> sources = {}; // unicast addresses that answered

  BulbStatus copy() => BulbStatus()
    ..on = on
    ..lightness = lightness
    ..hue = hue
    ..sat = sat
    ..workMode = workMode
    ..dps.addAll(dps)
    ..updated = updated
    ..sources.addAll(sources);

  int? get scene => dps[102];
  int? get countdown => dps[7];
  int? get battery => dps[103];

  /// Merge one decrypted access payload; returns true if it was understood.
  bool apply(Uint8List a) {
    if (a.length < 2) return false;
    int le(List<int> p, int i) => p[i] | (p[i + 1] << 8);
    final op2 = (a[0] << 8) | a[1];
    final p = a.sublist(2);
    switch (op2) {
      case 0x8204:
        if (p.isEmpty) return false;
        on = p[0] != 0;
      case 0x824E:
        if (p.length < 2) return false;
        lightness = le(p, 0) * 100 / 65535;
      case 0x8278:
        if (p.length < 6) return false;
        lightness = le(p, 0) * 100 / 65535;
        hue = le(p, 2) * 360 / 65536;
        sat = le(p, 4) * 100 / 65535;
      default:
        if (a[0] & 0xC0 == 0xC0 && a.length >= 4 && a[1] == (company & 0xFF) && a[2] == (company >> 8)) {
          if (a[0] & 0x3F != 0x0D) return false; // only reports
          final body = a.sublist(3); // [work mode][dp][type][value]...
          workMode = body[0] == 0 ? 0 : 1;
          var i = 1;
          while (i + 2 <= body.length) {
            final dp = body[i], type = body[i + 1];
            if (type != 0x01 && type != 0x02 && type != 0x04) break;
            final size = type == 0x02 ? 4 : 1;
            if (i + 2 + size > body.length) break;
            var v = 0;
            for (var j = 0; j < size; j++) {
              v = (v << 8) | body[i + 2 + j];
            }
            if (type == 0x02 && v >= 0x80000000) v -= 0x100000000;
            dps[dp] = v;
            i += 2 + size;
          }
        } else {
          return false;
        }
    }
    updated = DateTime.now();
    return true;
  }
}

// ---------- proxy configuration (talks to the connected proxy node only) ----------

/// Set Filter Type = blacklist with an empty list (= forward everything to us). Proxy reply: Filter Status.
Uint8List get proxySetFilter => _b([0x00, 0x01]);

/// Proxy PDU type 2: network PDU with CTL=1, TTL 0, dst 0, 64-bit NetMIC, proxy nonce.
Uint8List buildProxyConfigPdu(MeshKeys k, int src, int seq, Uint8List transport) {
  const ctlTtl = 0x80;
  final nonce = _b([3, 0, ..._be(seq, 3), ..._be(src, 2), 0, 0, ..._be(k.ivIndex, 4)]);
  final enc = _ccm(k.encKey, nonce, _b([0, 0, ...transport]), 64);
  final pecb = _aesEcb(k.privKey, _b([0, 0, 0, 0, 0, ..._be(k.ivIndex, 4), ...enc.sublist(0, 7)]));
  final hdr = [ctlTtl, ..._be(seq, 3), ..._be(src, 2)];
  return _b([2, ((k.ivIndex & 1) << 7) | k.nid, for (var i = 0; i < 6; i++) hdr[i] ^ pecb[i], ...enc]);
}

/// Decode a proxy configuration notification (full proxy PDU incl. header byte). Returns (src, transport).
(int, Uint8List)? parseProxyConfigPdu(MeshKeys k, Uint8List d) {
  if (d.length < 1 + 1 + 6 + 2 + 8 || d[0] & 0x3F != 2 || d[0] & 0xC0 != 0) return null;
  final pdu = d.sublist(1);
  if ((pdu[0] & 0x7F) != k.nid) return null;
  final enc = Uint8List.fromList(pdu.sublist(7));
  final pecb = _aesEcb(k.privKey, _b([0, 0, 0, 0, 0, ..._be(k.ivIndex, 4), ...enc.sublist(0, 7)]));
  final hdr = [for (var i = 0; i < 6; i++) pdu[1 + i] ^ pecb[i]];
  if (hdr[0] >> 7 != 1) return null;
  final seq = (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
  final src = (hdr[4] << 8) | hdr[5];
  final nonce = _b([3, 0, ..._be(seq, 3), ..._be(src, 2), 0, 0, ..._be(k.ivIndex, 4)]);
  final c = CCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(k.encKey), 64, nonce, Uint8List(0)));
  Uint8List clear;
  try {
    clear = c.process(enc);
  } catch (_) {
    return null;
  }
  if (clear.length < 3) return null;
  return (src, Uint8List.fromList(clear.sublist(2)));
}

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
