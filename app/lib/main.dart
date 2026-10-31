import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ble.dart';
import 'colour_wheel.dart';
import 'status_card.dart';
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
  Timer? _poll;
  bool _synced = false;

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
      _synced = false;
      b.status.addListener(() => _syncControls(b));
      setState(() => _bulb = b);
      _refresh();
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
    } catch (e) {
      _say(e);
    }
  }

  /// First status after connecting: move the controls to where the bulb actually is.
  void _syncControls(Bulb b) {
    final st = b.status.value;
    if (_synced || st.hue == null || st.lightness == null) return;
    _synced = true;
    setState(() {
      _hue = st.hue!;
      _sat = st.sat ?? _sat;
      if (st.workMode == 0) _bright = st.lightness!.clamp(0.0, 100.0);
    });
  }

  void _refresh() => _bulb?.refresh().catchError((Object e) => _say(e));

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _do(Future<void> Function(Bulb b) f) async {
    try {
      await f(_bulb!);
      Future.delayed(const Duration(milliseconds: 600), _refresh); // show the resulting state
    } catch (e) {
      _say(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bulb;
    return Scaffold(
      appBar: AppBar(title: const Text('Olight Sphere')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: b == null ? _setupView() : _controlView(b),
        ),
      ),
    );
  }

  Widget _setupView() => ListView(children: [
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
        if (_msg.isNotEmpty) Text(_msg, style: const TextStyle(color: Colors.red)),
      ]);

  /// Everything on one screen: no scrolling. The wheel takes whatever height is left.
  Widget _controlView(Bulb b) => Column(children: [
        ValueListenableBuilder<BulbStatus>(
            valueListenable: b.status, builder: (_, st, __) => StatusCard(status: st, onRefresh: _refresh)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: FilledButton(onPressed: () => _do((b) => b.setOn(true)), child: const Text('On'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.tonal(onPressed: () => _do((b) => b.setOn(false)), child: const Text('Off'))),
        ]),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ColourWheel(
                hue: _hue, sat: _sat,
                onChanged: (h, s) => setState(() { _hue = h; _sat = s; }),
                onChangeEnd: (h, s) {
                  setState(() { _hue = h; _sat = s; });
                  _do((b) => b.setColour(h, s));
                }),
          ),
        ),
        PresetRow(onPick: (h, s) {
          setState(() { _hue = h; _sat = s; });
          _do((b) => b.setColour(h, s));
        }),
        Row(children: [
          const Icon(Icons.brightness_6, size: 20),
          Expanded(
            child: Slider(
                value: _bright, max: 100,
                onChanged: (v) => setState(() => _bright = v),
                onChangeEnd: (v) => _do((b) => b.setBrightness(v))),
          ),
          TextButton(
              onPressed: () async {
                _poll?.cancel();
                await b.disconnect();
                setState(() => _bulb = null);
              },
              child: const Text('Disconnect')),
        ]),
        if (_msg.isNotEmpty) Text(_msg, style: const TextStyle(color: Colors.red, fontSize: 12), maxLines: 2),
      ]);
}
