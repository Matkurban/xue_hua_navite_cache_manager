import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../controllers/cache_workbench_controller.dart';

/// Tab 4: Manual in-memory byte storage (`putBytes`), offline lookup, and
/// 10,000+ entries stress benchmark.
class ManualPutTab extends StatelessWidget {
  const ManualPutTab({super.key, required this.controller});

  final CacheWorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Store In-Memory Bytes (putBytes)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller.manualKeyController,
                  decoration: const InputDecoration(
                    labelText: 'Cache Key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller.manualPayloadController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'UTF-8 Payload to Cache',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: controller.handlePutBytes,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Put Bytes into Cache'),
                    ),
                    OutlinedButton.icon(
                      onPressed: controller.handleOfflineLookup,
                      icon: const Icon(Icons.search),
                      label: const Text(
                        'Check Offline Cache (getFileFromCache)',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: controller.handleRemoveConfigTag,
                      icon: const Icon(Icons.label_off_outlined),
                      label: const Text('Remove Tag "config"'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'High-Volume 10,000+ Cache Entries Stress Benchmark',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SignalBuilder(
                  builder: (BuildContext context) =>
                      Text(controller.benchmarkReport.value),
                ),
                const SizedBox(height: 12),
                SignalBuilder(
                  builder: (BuildContext context) {
                    final bool busy = controller.isBusy.value;
                    return Wrap(
                      spacing: 12,
                      children: <Widget>[
                        FilledButton.tonalIcon(
                          onPressed: busy
                              ? null
                              : () => controller.runBulkBenchmark(1000),
                          icon: const Icon(Icons.speed),
                          label: const Text('Run 1,000 Entries Benchmark'),
                        ),
                        FilledButton.icon(
                          onPressed: busy
                              ? null
                              : () => controller.runBulkBenchmark(10000),
                          icon: const Icon(Icons.bolt),
                          label: const Text(
                            'Run 10,000+ Entries Stress Benchmark',
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
