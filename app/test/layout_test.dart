import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olight_sphere/colour_wheel.dart';
import 'package:olight_sphere/mesh.dart';
import 'package:olight_sphere/status_card.dart';

void main() {
  for (final size in const [Size(360, 560), Size(360, 700), Size(412, 915)]) {
    testWidgets('control screen fits without scrolling at $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final st = BulbStatus()
        ..on = true
        ..workMode = 1
        ..hue = 120
        ..sat = 100
        ..lightness = 50
        ..updated = DateTime.now()
        ..dps.addAll({102: 7, 103: 87, 7: 90});
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Olight Sphere')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Column(children: [
                StatusCard(status: st, onRefresh: () {}),
                Row(children: [
                  Expanded(child: FilledButton(onPressed: () {}, child: const Text('On'))),
                  Expanded(child: FilledButton(onPressed: () {}, child: const Text('Off'))),
                ]),
                Expanded(
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: ColourWheel(hue: 120, sat: 100, onChanged: (_, __) {}, onChangeEnd: (_, __) {}))),
                PresetRow(onPick: (_, __) {}),
                Row(children: [
                  Expanded(child: Slider(value: 50, max: 100, onChanged: (_) {})),
                  TextButton(onPressed: () {}, child: const Text('Disconnect')),
                ]),
              ]),
            ),
          ),
        ),
      ));
      expect(t.takeException(), isNull);
    });
  }
}
