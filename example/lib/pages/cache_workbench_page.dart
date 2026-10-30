import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../controllers/cache_workbench_controller.dart';
import '../tabs/cache_browser_tab.dart';
import '../tabs/cached_image_gallery_tab.dart';
import '../tabs/config_capabilities_tab.dart';
import '../tabs/download_tab.dart';
import '../tabs/manual_put_tab.dart';
import '../widgets/status_banner.dart';

/// Main 5-tab workbench page for `xue_hua_navite_cache_manager`.
///
/// Uses [CacheWorkbenchController] and `signals_flutter` [SignalBuilder] for
/// surgical widget rebuilds without `setState`.
class CacheWorkbenchPage extends StatefulWidget {
  const CacheWorkbenchPage({super.key});

  @override
  State<CacheWorkbenchPage> createState() => _CacheWorkbenchPageState();
}

class _CacheWorkbenchPageState extends State<CacheWorkbenchPage> {
  late final CacheWorkbenchController _controller = CacheWorkbenchController();

  @override
  void initState() {
    super.initState();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('XueHua Native Cache Manager'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Refresh Stats',
              onPressed: _controller.refreshDashboard,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            onTap: (_) => _controller.refreshDashboard(),
            tabs: const <Widget>[
              Tab(icon: Icon(Icons.cloud_download), text: 'Download & Fetch'),
              Tab(
                icon: Icon(Icons.photo_library),
                text: 'CachedNetworkImage (104)',
              ),
              Tab(icon: Icon(Icons.folder_special), text: 'Cache Browser'),
              Tab(icon: Icon(Icons.memory), text: 'Manual Put & 10K Bench'),
              Tab(icon: Icon(Icons.tune), text: 'Config & Capabilities'),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            StatusBanner(controller: _controller),
            Expanded(
              child: SignalBuilder(
                builder: (BuildContext context) {
                  if (!_controller.isReady.value) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return TabBarView(
                    children: <Widget>[
                      DownloadTab(controller: _controller),
                      CachedImageGalleryTab(controller: _controller),
                      CacheBrowserTab(controller: _controller),
                      ManualPutTab(controller: _controller),
                      ConfigCapabilitiesTab(controller: _controller),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
