import 'package:flutter_driver/flutter_driver.dart';
import 'package:test/test.dart';

Future<String> treeText(FlutterDriver driver) async {
  return (await driver.getRenderTree()).tree ?? '';
}

Future<void> tapText(FlutterDriver driver, String text) async {
  await driver.waitFor(find.text(text), timeout: const Duration(seconds: 30));
  await driver.tap(find.text(text));
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

void main() {
  late FlutterDriver driver;

  setUpAll(() async {
    driver = await FlutterDriver.connect();
    await driver.waitFor(
      find.text('Download & Fetch'),
      timeout: const Duration(seconds: 60),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
  });

  tearDownAll(() async {
    await driver.close();
  });

  test('10k stress benchmark via UI', () async {
    await tapText(driver, 'Manual Put & 10K Bench');
    await tapText(driver, 'Run 10,000+ Entries Stress Benchmark');
    var ok = false;
    for (var i = 0; i < 300; i++) {
      final tree = await treeText(driver);
      if (tree.contains('Benchmark error')) {
        final idx = tree.indexOf('Benchmark error');
        fail(
          'Benchmark error: '
          '${tree.substring(idx, (idx + 250).clamp(0, tree.length))}',
        );
      }
      if (tree.contains('Benchmark (10000 entries) passed') ||
          tree.contains('Write 10000 entries') ||
          tree.contains('Completed 10000-entry benchmark')) {
        ok = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(ok, isTrue, reason: '10,000-entry benchmark did not finish');
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('Gallery clear disk tag then prefetch 24 again', () async {
    await tapText(driver, 'CachedNetworkImage (104)');
    await tapText(driver, 'Clear Disk & Memory ("gallery")');
    await Future<void>.delayed(const Duration(seconds: 3));
    await tapText(driver, 'Prefetch First 24');
    await Future<void>.delayed(const Duration(seconds: 50));
    final tree = await treeText(driver);
    expect(tree.contains('Gallery prefetch error'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
