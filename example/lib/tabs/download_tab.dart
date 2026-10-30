import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

import '../constants/workbench_presets.dart';
import '../controllers/cache_workbench_controller.dart';

/// Tab 1: Network file download, preset selection, checksum validation, and
/// last fetch result inspection.
class DownloadTab extends StatelessWidget {
  const DownloadTab({super.key, required this.controller});

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
                  'Preset Network Resources',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: kSampleUrls.map((Map<String, String> preset) {
                    return ActionChip(
                      avatar: const Icon(Icons.link, size: 16),
                      label: Text(preset['label']!),
                      onPressed: () => controller.selectPreset(preset),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller.urlController,
                  decoration: const InputDecoration(
                    labelText: 'Remote File URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: controller.customKeyController,
                        decoration: const InputDecoration(
                          labelText: 'Custom Key (Optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: controller.tagController,
                        decoration: const InputDecoration(
                          labelText: 'Category Tag (e.g. images)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    SignalBuilder(
                      builder: (BuildContext context) =>
                          DropdownButton<CacheChecksumAlgorithm>(
                            value: controller.checksumAlgorithm.value,
                            onChanged: (CacheChecksumAlgorithm? val) {
                              if (val != null) {
                                controller.checksumAlgorithm.value = val;
                              }
                            },
                            items: CacheChecksumAlgorithm.values
                                .map(
                                  (
                                    CacheChecksumAlgorithm alg,
                                  ) => DropdownMenuItem<CacheChecksumAlgorithm>(
                                    value: alg,
                                    child: Text(
                                      'Hash: ${alg.wireValue.toUpperCase()}',
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: controller.expectedHashController,
                        decoration: const InputDecoration(
                          labelText: 'Expected Checksum Hex (Optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  children: <Widget>[
                    SignalBuilder(
                      builder: (BuildContext context) => FilterChip(
                        label: const Text('Force Refresh'),
                        selected: controller.forceRefresh.value,
                        onSelected: (bool v) =>
                            controller.forceRefresh.value = v,
                      ),
                    ),
                    SignalBuilder(
                      builder: (BuildContext context) => FilterChip(
                        label: const Text('Fallback to Stale Cache on Error'),
                        selected: controller.fallbackOnError.value,
                        onSelected: (bool v) =>
                            controller.fallbackOnError.value = v,
                      ),
                    ),
                    SignalBuilder(
                      builder: (BuildContext context) => FilterChip(
                        label: const Text('Pin Entry (Prevent Eviction)'),
                        selected: controller.pinNewEntry.value,
                        onSelected: (bool v) =>
                            controller.pinNewEntry.value = v,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SignalBuilder(
                  builder: (BuildContext context) {
                    final bool busy = controller.isBusy.value;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: busy ? null : controller.handleDownload,
                          icon: const Icon(Icons.download),
                          label: const Text('Fetch / Cache File'),
                        ),
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : controller.handlePrefetchBatch,
                          icon: const Icon(Icons.playlist_add_check),
                          label: const Text('Batch Prefetch Presets'),
                        ),
                        TextButton.icon(
                          onPressed: controller.handleCancelInFlight,
                          icon: const Icon(Icons.cancel_outlined),
                          label: const Text('Cancel In-Flight'),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        SignalBuilder(
          builder: (BuildContext context) {
            final CacheFetchResult? res = controller.lastFetchResult.value;
            final Uint8List? previewBytes = controller.previewBytes.value;
            if (res == null) {
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
                        'Last Fetch Result (${res.source.wireValue})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text('Key: ${res.entry.key}'),
                      Text('Local Path / URI: ${res.entry.filePath}'),
                      Text(
                        'Size: ${formatByteSize(res.entry.sizeBytes)} • Elapsed: ${res.elapsedMs} ms • HTTP: ${res.httpStatusCode ?? "N/A (Cache Hit)"}',
                      ),
                      Text(
                        'MIME: ${res.entry.mimeType ?? "unknown"} • Hits: ${res.entry.hitCount} • Pinned: ${res.entry.pinned}',
                      ),
                      if (res.entry.checksum != null)
                        Text(
                          'Checksum (${res.entry.checksumAlgorithm.wireValue}): ${res.entry.checksum}',
                        ),
                      if (previewBytes != null &&
                          (res.entry.mimeType?.startsWith('image/') ??
                              false)) ...<Widget>[
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            previewBytes,
                            height: 180,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ],
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
