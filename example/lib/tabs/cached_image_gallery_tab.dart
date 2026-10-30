import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

import '../controllers/cache_workbench_controller.dart';

/// Tab 2: 104 public images wall demonstrating [CachedNetworkImage] with
/// hardware-accelerated `borderRadius`, `imageBuilder`, and `errorBuilder`.
class CachedImageGalleryTab extends StatelessWidget {
  const CachedImageGalleryTab({super.key, required this.controller});

  final CacheWorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '104 Public Images Wall (CachedNetworkImage)',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      SignalBuilder(
                        builder: (BuildContext context) => FilterChip(
                          label: const Text('Include Broken URL Test Card'),
                          selected: controller.simulateBrokenCard.value,
                          onSelected: controller.setSimulateBrokenCard,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      SignalBuilder(
                        builder: (BuildContext context) {
                          final bool busy = controller.isBusy.value;
                          return FilledButton.tonalIcon(
                            onPressed: busy
                                ? null
                                : () => controller.handlePrefetchGalleryImages(
                                    24,
                                  ),
                            icon: const Icon(Icons.flash_on, size: 18),
                            label: const Text('Prefetch First 24'),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        onPressed: controller.clearMemoryImageCacheOnly,
                        icon: const Icon(Icons.memory, size: 18),
                        label: const Text('Clear Memory ImageCache Only'),
                      ),
                      OutlinedButton.icon(
                        onPressed: controller.clearGalleryDiskAndMemory,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('Clear Disk & Memory ("gallery")'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: SignalBuilder(
            builder: (BuildContext context) {
              final List<Map<String, String>> items =
                  controller.galleryItems.value;
              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.05,
                ),
                itemCount: items.length,
                itemBuilder: (BuildContext context, int index) {
                  final Map<String, String> item = items[index];
                  final bool isCircleDemo = index == 2;
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(
                          child: CachedNetworkImage(
                            imageUrl: item['url']!,
                            tag: 'gallery',
                            pinned: index == 1,
                            memCacheWidth: 360,
                            borderRadius: BorderRadius.circular(12),
                            fit: BoxFit.cover,
                            imageBuilder: isCircleDemo
                                ? (
                                    BuildContext context,
                                    ImageProvider provider,
                                  ) => Center(
                                    child: CircleAvatar(
                                      radius: 52,
                                      backgroundImage: provider,
                                    ),
                                  )
                                : null,
                            progressIndicatorBuilder:
                                (
                                  BuildContext context,
                                  String url,
                                  ImageChunkEvent? progress,
                                ) {
                                  final int? total =
                                      progress?.expectedTotalBytes;
                                  double? ratio;
                                  if (progress != null &&
                                      total != null &&
                                      total > 0) {
                                    final double raw =
                                        progress.cumulativeBytesLoaded / total;
                                    if (raw < 0) {
                                      ratio = 0;
                                    } else if (raw > 1) {
                                      ratio = 1;
                                    } else {
                                      ratio = raw;
                                    }
                                  }
                                  if (ratio == null) {
                                    return const Center(
                                      child: Icon(
                                        Icons.image_outlined,
                                        size: 28,
                                      ),
                                    );
                                  }
                                  return Center(
                                    child: SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        value: ratio,
                                      ),
                                    ),
                                  );
                                },
                            errorBuilder:
                                (
                                  BuildContext context,
                                  String url,
                                  Object error,
                                  StackTrace? stackTrace,
                                ) {
                                  return const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Icon(
                                          Icons.broken_image_outlined,
                                          size: 32,
                                          color: Colors.redAccent,
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          'Load Failed',
                                          style: TextStyle(fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Text(
                            item['title']!,
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
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
