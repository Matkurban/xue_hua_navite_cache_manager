import 'package:material_ui/material_ui.dart';
import 'package:xue_hua_navite_cache_manager_example/app_theme.dart';
import 'package:xue_hua_navite_cache_manager_example/pages/cache_workbench_page.dart';

export 'package:xue_hua_navite_cache_manager_example/pages/cache_workbench_page.dart';

void main() {
  runApp(const CacheManagerDemoApp());
}

/// Comprehensive full-feature example application for `xue_hua_navite_cache_manager` v1.2.0.
class CacheManagerDemoApp extends StatelessWidget {
  const CacheManagerDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XueHua Native Cache Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: const CacheWorkbenchPage(),
    );
  }
}
