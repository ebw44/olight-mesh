import 'package:flutter/material.dart';

import 'mesh.dart';

const _scenes = {
  1: 'Cotton Candy', 2: 'Aurora', 3: 'Fireworks', 4: 'Fountain', 7: 'Custom colour',
  8: 'Red blinking', 18: 'Vibrant', 20: 'Plain red', 30: 'Candy Cane',
};

String _countdown(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

/// Compact live view of what the bulb last reported (two lines + lamp).
class StatusCard extends StatelessWidget {
  const StatusCard({super.key, required this.status, required this.onRefresh, this.target = ''});
  final BulbStatus status;
  final String target; // where commands go, e.g. 0x0040 or all nodes
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
    final age = s.updated == null ? null : DateTime.now().difference(s.updated!).inSeconds;
    final details = [
      if (s.lightness != null) '${(colourMode ? s.lightness! * 2 : s.lightness!).clamp(0, 100).round()}%',
      if (colourMode) 'H ${s.hue!.round()}° S ${s.sat!.round()}%',
      if (s.scene != null) _scenes[s.scene] ?? 'Scene ${s.scene}',
      if (s.battery != null) 'Batt ${s.battery}%',
      if (s.countdown != null && s.countdown! > 0) 'Timer ${_countdown(s.countdown!)}',
      if (target.isNotEmpty) '→ $target',
      if (s.sources.isNotEmpty) 'from ${(s.sources.toList()..sort()).map((a) => '0x${a.toRadixString(16).padLeft(4, '0')}').join(',')}',
    ].join('  ·  ');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: lamp,
              border: Border.all(color: Colors.black26, width: 1.5),
              boxShadow: on == true ? [BoxShadow(color: lamp.withValues(alpha: .6), blurRadius: 12)] : null,
            ),
            child: Icon(Icons.lightbulb, size: 22, color: on == false ? Colors.black38 : Colors.black54),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '${on == null ? 'Unknown' : on ? 'On' : 'Off'}'
                '${s.workMode == null ? '' : s.workMode == 1 ? ' · Colour' : ' · White'}',
                style: t.textTheme.titleMedium,
              ),
              Text(
                details.isEmpty ? (age == null ? 'No reply yet' : '') : details,
                style: t.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
        ]),
      ),
    );
  }
}
