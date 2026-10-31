import 'package:flutter/material.dart';

import 'mesh.dart';

const _scenes = {
  1: 'Cotton Candy', 2: 'Aurora', 3: 'Fireworks', 4: 'Fountain', 7: 'Custom colour',
  8: 'Red blinking', 18: 'Vibrant', 20: 'Plain red', 30: 'Candy Cane',
};

String _countdown(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

/// Live view of what the bulb last reported.
class StatusCard extends StatelessWidget {
  const StatusCard({super.key, required this.status, required this.onRefresh});
  final BulbStatus status;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final t = Theme.of(context);
    final on = s.on;
    final colourMode = s.workMode == 1 && s.hue != null && s.sat != null;
    final lamp = on == false
        ? t.colorScheme.surfaceContainerHighest
        : colourMode
            ? HSLColor.fromAHSL(1, s.hue!, s.sat! / 100, 0.5 + (1 - s.sat! / 100) * 0.5).toColor()
            : const Color(0xFFFFF1C9);
    final pct = s.lightness;
    final age = s.updated == null ? null : DateTime.now().difference(s.updated!).inSeconds;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: lamp,
                border: Border.all(color: Colors.black26, width: 1.5),
                boxShadow: on == true ? [BoxShadow(color: lamp.withValues(alpha: .6), blurRadius: 18, spreadRadius: 2)] : null,
              ),
              child: Icon(Icons.lightbulb, color: on == false ? Colors.black38 : Colors.black54),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(on == null ? 'Unknown' : on ? 'On' : 'Off', style: t.textTheme.headlineSmall),
                Text(
                  s.workMode == null ? 'mode unknown' : s.workMode == 1 ? 'Colour mode' : 'White mode',
                  style: t.textTheme.bodySmall,
                ),
              ]),
            ),
            IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          ]),
          if (pct != null) ...[
            const SizedBox(height: 12),
            Row(children: [
              const SizedBox(width: 90, child: Text('Brightness')),
              Expanded(child: LinearProgressIndicator(value: (pct / 100).clamp(0.0, 1.0), minHeight: 8)),
              SizedBox(width: 48, child: Text('${pct.round()}%', textAlign: TextAlign.end)),
            ]),
          ],
          if (s.battery != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              const SizedBox(width: 90, child: Text('Battery')),
              Expanded(child: LinearProgressIndicator(value: (s.battery! / 100).clamp(0.0, 1.0), minHeight: 8)),
              SizedBox(width: 48, child: Text('${s.battery}%', textAlign: TextAlign.end)),
            ]),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if (colourMode) Chip(label: Text('Hue ${s.hue!.round()}°  Sat ${s.sat!.round()}%')),
            if (s.scene != null) Chip(label: Text(_scenes[s.scene] ?? 'Scene ${s.scene}')),
            if (s.countdown != null && s.countdown! > 0)
              Chip(avatar: const Icon(Icons.timer, size: 18), label: Text('Toggles in ${_countdown(s.countdown!)}')),
          ]),
          const SizedBox(height: 4),
          Text(age == null ? 'No reply yet' : 'Updated ${age}s ago', style: t.textTheme.bodySmall),
        ]),
      ),
    );
  }
}
