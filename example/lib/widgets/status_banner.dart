import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

import '../constants/workbench_presets.dart';
import '../controllers/cache_workbench_controller.dart';

/// Top status banner displaying the latest log message, cache summary chip,
/// and real-time download progress bar with fine-grained [SignalBuilder] scopes.
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.controller});

  final CacheWorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: SignalBuilder(
                  builder: (BuildContext context) => Text(
                    controller.statusLog.value,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              SignalBuilder(
                builder: (BuildContext context) {
                  final CacheStats? stats = controller.stats.value;
                  if (stats == null) {
                    return const SizedBox.shrink();
                  }
                  return Chip(
                    label: Text(
                      '${stats.totalEntries} files • ${formatByteSize(stats.totalBytes)} • Hit ${(stats.hitRate * 100).toStringAsFixed(0)}%',
                    ),
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ],
          ),
          SignalBuilder(
            builder: (BuildContext context) {
              final CacheProgressEvent? progress =
                  controller.latestProgress.value;
              if (progress == null) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: <Widget>[
                    Text(
                      'Event [${progress.state.wireValue}]: ',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: progress.state == CacheTransferState.failed
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                    Expanded(
                      // Keep a non-null progress value so flutter_driver waitFor
                      // does not block on an indeterminate ticker.
                      child: LinearProgressIndicator(
                        value: progress.progress ?? 0,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${formatByteSize(progress.bytesReceived)}'
                      '${progress.totalBytes > 0 ? " / ${formatByteSize(progress.totalBytes)}" : ""}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
