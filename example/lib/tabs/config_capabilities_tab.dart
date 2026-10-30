import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

import '../constants/workbench_presets.dart';
import '../controllers/cache_workbench_controller.dart';

/// Tab 5: Global cache configuration, host platform capabilities, and live
/// cache telemetry.
class ConfigCapabilitiesTab extends StatelessWidget {
  const ConfigCapabilitiesTab({super.key, required this.controller});

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
                  'Global Cache Configuration',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    const Text('Eviction Policy: '),
                    const SizedBox(width: 12),
                    SignalBuilder(
                      builder: (BuildContext context) =>
                          DropdownButton<CacheEvictionPolicy>(
                            value: controller.evictionPolicy.value,
                            onChanged: (CacheEvictionPolicy? policy) {
                              if (policy != null) {
                                controller.evictionPolicy.value = policy;
                              }
                            },
                            items: CacheEvictionPolicy.values
                                .map(
                                  (CacheEvictionPolicy p) =>
                                      DropdownMenuItem<CacheEvictionPolicy>(
                                        value: p,
                                        child: Text(p.wireValue.toUpperCase()),
                                      ),
                                )
                                .toList(),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SignalBuilder(
                  builder: (BuildContext context) {
                    final int quotaMb = controller.maxQuotaMb.value;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Max Disk Quota: $quotaMb MB'),
                        Slider(
                          value: quotaMb.toDouble(),
                          min: 5,
                          max: 500,
                          divisions: 99,
                          label: '$quotaMb MB',
                          onChanged: (double v) =>
                              controller.maxQuotaMb.value = v.round(),
                        ),
                      ],
                    );
                  },
                ),
                FilledButton.icon(
                  onPressed: () => controller.applyConfiguration(),
                  icon: const Icon(Icons.check),
                  label: const Text('Apply Configuration'),
                ),
              ],
            ),
          ),
        ),
        SignalBuilder(
          builder: (BuildContext context) {
            final CachePlatformCapabilities? caps =
                controller.capabilities.value;
            if (caps == null) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Host Platform Capabilities (${caps.platformName.toUpperCase()})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('Storage Engine: ${caps.storageMechanism}'),
                      Text('Default Cache Root: ${caps.defaultCacheRootPath}'),
                      Text(
                        'Supports Native OS File Paths: ${caps.supportsFileSystemPaths}',
                      ),
                      Text(
                        'Supports HTTP 304 Revalidation: ${caps.supportsConditionalHttpRevalidation}',
                      ),
                      Text(
                        'Supports Native Crypto Hashing: ${caps.supportsNativeCryptoHash}',
                      ),
                      Text(
                        'OS Low-Disk-Space Auto-Purge: ${caps.supportsLowDiskSpaceNotifications}',
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        SignalBuilder(
          builder: (BuildContext context) {
            final CacheStats? stats = controller.stats.value;
            if (stats == null) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Live Cache Telemetry',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('Total Entries: ${stats.totalEntries}'),
                      Text('Total Size: ${formatByteSize(stats.totalBytes)}'),
                      Text(
                        'Quota Usage: ${(stats.quotaUsageRatio * 100).toStringAsFixed(1)}%',
                      ),
                      Text(
                        'Hits / Misses / Evictions: ${stats.hitCount} / ${stats.missCount} / ${stats.evictionCount}',
                      ),
                      Text('Pinned Entries: ${stats.pinnedEntries}'),
                      Text('Expired Entries: ${stats.expiredEntries}'),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
