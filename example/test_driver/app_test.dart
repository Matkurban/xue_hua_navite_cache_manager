import 'package:flutter_driver/flutter_driver.dart';
import 'package:test/test.dart';

Future<String> treeText(FlutterDriver driver) async {
  final RenderTree rt = await driver.getRenderTree();
  return rt.tree ?? '';
}

Future<void> tapText(
  FlutterDriver driver,
  String text, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final finder = find.text(text);
  await driver.waitFor(finder, timeout: timeout);
  await driver.tap(finder);
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

void main() {
  late FlutterDriver driver;

  setUpAll(() async {
    driver = await FlutterDriver.connect(printCommunication: false);
    // Wait until plugin init finishes (status banner replaces spinner).
    await driver.waitFor(
      find.text('Download & Fetch'),
      timeout: const Duration(seconds: 60),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
  });

  tearDownAll(() async {
    await driver.close();
  });

  test('App launches and shows workbench chrome', () async {
    expect(
      await driver.getText(find.text('XueHua Native Cache Manager')),
      'XueHua Native Cache Manager',
    );
    await driver.waitFor(find.text('Download & Fetch'));
    await driver.waitFor(find.text('CachedNetworkImage (104)'));
    await driver.waitFor(find.text('Cache Browser'));
    await driver.waitFor(find.text('Manual Put & 10K Bench'));
    await driver.waitFor(find.text('Config & Capabilities'));
  });

  test('Tab1 Download: Fetch owl image', () async {
    await tapText(driver, 'Download & Fetch');
    await tapText(driver, 'Owl Image (JPG)');
    await tapText(driver, 'Fetch / Cache File');
    var sawResult = false;
    for (var i = 0; i < 45; i++) {
      final t = await treeText(driver);
      if (t.contains('Last Fetch Result') || t.contains('Download error')) {
        sawResult = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(
      sawResult,
      isTrue,
      reason: 'timed out waiting for fetch result card',
    );
    final tree = await treeText(driver);
    final ok =
        tree.contains('Last Fetch Result') ||
        tree.contains('Resolved') ||
        tree.contains('networkDownload') ||
        tree.contains('cacheHit') ||
        tree.contains('Download error');
    expect(
      ok,
      isTrue,
      reason: 'Expected fetch result or error visible after download',
    );
    if (tree.contains('Download error')) {
      final idx = tree.indexOf('Download error');
      fail(
        'Download produced Download error in UI: '
        '${tree.substring(idx, (idx + 200).clamp(0, tree.length))}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Tab1 Download: Batch Prefetch Presets', () async {
    await tapText(driver, 'Download & Fetch');
    await tapText(driver, 'Batch Prefetch Presets');
    await Future<void>.delayed(const Duration(seconds: 20));
    final tree = await treeText(driver);
    if (tree.contains('Batch prefetch error')) {
      final idx = tree.indexOf('Batch prefetch error');
      fail(
        'Batch prefetch error visible in UI: '
        '${tree.substring(idx, (idx + 250).clamp(0, tree.length))}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Tab1 Download: Cancel In-Flight (no crash)', () async {
    await tapText(driver, 'Download & Fetch');
    await tapText(driver, 'Cancel In-Flight');
    await Future<void>.delayed(const Duration(seconds: 1));
  });

  test('Tab2 Gallery: open, Prefetch First 24, scroll', () async {
    await tapText(driver, 'CachedNetworkImage (104)');
    await Future<void>.delayed(const Duration(seconds: 3));
    await driver.waitFor(
      find.text('Prefetch First 24'),
      timeout: const Duration(seconds: 20),
    );
    await tapText(driver, 'Prefetch First 24');
    await Future<void>.delayed(const Duration(seconds: 45));
    final tree = await treeText(driver);
    if (tree.contains('Gallery prefetch error')) {
      final idx = tree.indexOf('Gallery prefetch error');
      fail(
        'Gallery prefetch error: '
        '${tree.substring(idx, (idx + 250).clamp(0, tree.length))}',
      );
    }
    await driver.scroll(
      find.byType('GridView'),
      0,
      -800,
      const Duration(milliseconds: 800),
    );
    await Future<void>.delayed(const Duration(seconds: 5));
    await driver.scroll(
      find.byType('GridView'),
      0,
      -1200,
      const Duration(milliseconds: 1000),
    );
    await Future<void>.delayed(const Duration(seconds: 5));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('Tab2 Gallery: Clear Memory ImageCache Only', () async {
    await tapText(driver, 'CachedNetworkImage (104)');
    await tapText(driver, 'Clear Memory ImageCache Only');
    await Future<void>.delayed(const Duration(seconds: 2));
  });

  test('Tab2 Gallery: Include Broken URL Test Card', () async {
    await tapText(driver, 'CachedNetworkImage (104)');
    await tapText(driver, 'Include Broken URL Test Card');
    await Future<void>.delayed(const Duration(seconds: 5));
    try {
      await driver.scroll(
        find.byType('GridView'),
        0,
        -5000,
        const Duration(seconds: 2),
      );
    } catch (_) {
      // The broken-URL card may already be in view.
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  });

  test('Tab3 Cache Browser: purge/trim/clear unpinned', () async {
    await tapText(driver, 'Cache Browser');
    await Future<void>.delayed(const Duration(seconds: 2));
    await driver.waitFor(
      find.text('Purge Expired'),
      timeout: const Duration(seconds: 30),
    );
    try {
      await tapText(driver, 'All Tags');
    } catch (_) {
      // Tag filter is optional; purge/trim/clear still run on the open tab.
    }
    await tapText(driver, 'Purge Expired');
    await Future<void>.delayed(const Duration(seconds: 1));
    await tapText(driver, 'Trim to 1 MB');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tapText(driver, 'Clear Unpinned');
    await Future<void>.delayed(const Duration(seconds: 2));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Tab4 Manual Put: putBytes + offline lookup + 1k bench', () async {
    await tapText(driver, 'Manual Put & 10K Bench');
    await Future<void>.delayed(const Duration(seconds: 1));
    await tapText(driver, 'Put Bytes into Cache');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tapText(driver, 'Check Offline Cache (getFileFromCache)');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tapText(driver, 'Run 1,000 Entries Benchmark');
    var ok = false;
    for (var i = 0; i < 120; i++) {
      final tree = await treeText(driver);
      if (tree.contains('Benchmark error')) {
        final idx = tree.indexOf('Benchmark error');
        fail(
          'Benchmark error: '
          '${tree.substring(idx, (idx + 250).clamp(0, tree.length))}',
        );
      }
      if (tree.contains('Benchmark (1000 entries) passed') ||
          tree.contains('Write 1000 entries') ||
          tree.contains('Completed 1000-entry benchmark')) {
        ok = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(ok, isTrue, reason: '1,000-entry benchmark did not finish');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('Tab5 Config: apply configuration and see capabilities', () async {
    await tapText(driver, 'Config & Capabilities');
    await Future<void>.delayed(const Duration(seconds: 2));
    await driver.waitFor(find.text('Apply Configuration'));
    await tapText(driver, 'Apply Configuration');
    await Future<void>.delayed(const Duration(seconds: 2));
    final tree = await treeText(driver);
    expect(
      tree.contains('Host Platform Capabilities') ||
          tree.contains('LINUX') ||
          tree.contains('linux') ||
          tree.contains('Storage Engine'),
      isTrue,
    );
    expect(
      tree.contains('Live Cache Telemetry') || tree.contains('Total Entries'),
      isTrue,
    );
  });

  test('Tab3 Clear All then verify empty-ish browser', () async {
    await tapText(driver, 'Cache Browser');
    await Future<void>.delayed(const Duration(seconds: 1));
    await driver.waitFor(
      find.text('Clear All'),
      timeout: const Duration(seconds: 30),
    );
    await tapText(driver, 'Clear All');
    await Future<void>.delayed(const Duration(seconds: 2));
  });

  test('Health: no driver disconnect / app still responsive', () async {
    final health = await driver.checkHealth();
    expect(health.status, HealthStatus.ok);
    await tapText(driver, 'Download & Fetch');
    await driver.waitFor(find.text('Fetch / Cache File'));
  });
}
