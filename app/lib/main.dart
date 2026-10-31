import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ble.dart';
import 'mesh.dart';

void main() => runApp(const MaterialApp(home: Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  static const _store = FlutterSecureStorage();
  final _keysCtl = TextEditingController();
  MeshKeys? _keys;
  Bulb? _bulb;
  String _msg = '';
  double _bright = 100, _hue = 0, _sat = 100;

  @override
  void initState() {
    super.initState();
    _store.read(key: 'keys').then((v) {
      if (v != null) _keysCtl.text = v;
      _saveKeys(save: false);
    });
  }

  void _say(Object e) => setState(() => _msg = '$e');

  Future<void> _saveKeys({bool save = true}) async {
    try {
      final k = MeshKeys.fromJson(_keysCtl.text);
      if (save) await _store.write(key: 'keys', value: _keysCtl.text);
      setState(() => _keys = k);
    } catch (e) {
      if (save) _say(e);
    }
  }

  Future<void> _scan() async {
    try {
      await FlutterBluePlus.startScan(withServices: [proxySvc], timeout: const Duration(seconds: 8));
    } catch (e) {
      _say(e);
    }
  }

  Future<void> _connect(BluetoothDevice d) async {
    final b = Bulb(_keys!, d);
    try {
      await b.connect();
      setState(() => _bulb = b);
    } catch (e) {
      _say(e);
    }
  }

  Future<void> _do(Future<void> Function(Bulb b) f) async {
    try {
      await f(_bulb!);
    } catch (e) {
      _say(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bulb;
    return Scaffold(
      appBar: AppBar(title: const Text('Olight Sphere')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (b == null) ...[
          TextField(
              controller: _keysCtl, maxLines: 6, decoration: const InputDecoration(labelText: 'keys.json (paste)')),
          Row(children: [
            TextButton(onPressed: _saveKeys, child: const Text('Save keys')),
            TextButton(onPressed: _keys == null ? null : _scan, child: const Text('Scan')),
          ]),
          StreamBuilder<List<ScanResult>>(
            stream: FlutterBluePlus.scanResults,
            builder: (_, s) => Column(children: [
              for (final r in s.data ?? [])
                ListTile(
                    title: Text(r.device.platformName.isEmpty ? '(unnamed)' : r.device.platformName),
                    subtitle: Text(r.device.remoteId.str),
                    onTap: () => _connect(r.device)),
            ]),
          ),
        ] else ...[
          Row(children: [
            FilledButton(onPressed: () => _do((b) => b.setOn(true)), child: const Text('On')),
            const SizedBox(width: 12),
            FilledButton(onPressed: () => _do((b) => b.setOn(false)), child: const Text('Off')),
            const Spacer(),
            TextButton(
                onPressed: () async {
                  await b.disconnect();
                  setState(() => _bulb = null);
                },
                child: const Text('Disconnect')),
          ]),
          const Text('Brightness (white)'),
          Slider(
              value: _bright, max: 100,
              onChanged: (v) => setState(() => _bright = v),
              onChangeEnd: (v) => _do((b) => b.setBrightness(v))),
          const Text('Hue (colour)'),
          Slider(
              value: _hue, max: 360,
              onChanged: (v) => setState(() => _hue = v),
              onChangeEnd: (v) => _do((b) => b.setColour(v, _sat))),
          const Text('Saturation'),
          Slider(
              value: _sat, max: 100,
              onChanged: (v) => setState(() => _sat = v),
              onChangeEnd: (v) => _do((b) => b.setColour(_hue, v))),
        ],
        if (_msg.isNotEmpty) Text(_msg, style: const TextStyle(color: Colors.red)),
      ]),
    );
  }
}
