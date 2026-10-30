import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

import '../constants/workbench_presets.dart';
import '../controllers/cache_workbench_controller.dart';

/// Tab 3: Interactive cache browser with tag filtering, pinning, byte inspection,
/// and selective eviction controls.
class CacheBrowserTab extends StatelessWidget {
  const CacheBrowserTab({super.key, required this.controller});

  final CacheWorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: SignalBuilder(
            builder: (BuildContext context) {
              final CacheStats? stats = controller.stats.value;
              final List<String> tags = controller.availableTags.value;
              final String? selectedFilter = controller.selectedTagFilter.value;

              return Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  ChoiceChip(
                    label: const Text('All Tags'),
                    selected: selectedFilter == null,
                    onSelected: (_) => controller.selectTagFilter(null),
                  ),
                  ...tags.map(
                    (String t) => ChoiceChip(
                      label: Text(
                        '$t (${formatByteSize(stats?.bytesByTag[t] ?? 0)})',
                      ),
                      selected: selectedFilter == t,
                      onSelected: (_) => controller.selectTagFilter(t),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.purgeExpired,
                    icon: const Icon(Icons.timer_off_outlined, size: 18),
                    label: const Text('Purge Expired'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.trimToOneMegabyte,
                    icon: const Icon(Icons.compress, size: 18),
                    label: const Text('Trim to 1 MB'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: controller.clearUnpinned,
                    icon: const Icon(
                      Icons.cleaning_services_outlined,
                      size: 18,
                    ),
                    label: const Text('Clear Unpinned'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: controller.clearAllEntries,
                    icon: const Icon(Icons.delete_forever, size: 18),
                    label: const Text('Clear All'),
                  ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: SignalBuilder(
            builder: (BuildContext context) {
              final List<CacheEntry> entries = controller.entries.value;
              if (entries.isEmpty) {
                return const Center(
                  child: Text('No cached files match the current filter.'),
                );
              }
              return ListView.builder(
                itemCount: entries.length,
                itemBuilder: (BuildContext context, int index) {
                  final CacheEntry entry = entries[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: ListTile(
                      leading: Icon(
                        entry.pinned ? Icons.push_pin : Icons.insert_drive_file,
                        color: entry.pinned
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(
                        entry.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'Key: ${entry.key.length > 16 ? "${entry.key.substring(0, 16)}..." : entry.key} • '
                        '${formatByteSize(entry.sizeBytes)} • Hits: ${entry.hitCount} • '
                        'Tag: ${entry.tag ?? "none"} • Expired: ${entry.isExpired}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            tooltip: entry.pinned ? 'Unpin' : 'Pin',
                            icon: Icon(
                              entry.pinned
                                  ? Icons.lock
                                  : Icons.lock_open_outlined,
                            ),
                            onPressed: () => controller.togglePinEntry(entry),
                          ),
                          IconButton(
                            tooltip: 'Read Bytes',
                            icon: const Icon(Icons.visibility_outlined),
                            onPressed: () => controller.inspectEntry(entry),
                          ),
                          IconButton(
                            tooltip: 'Delete Entry',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => controller.deleteEntry(entry),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
