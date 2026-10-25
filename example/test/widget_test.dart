import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_cache_manager_example/main.dart';

void main() {
  testWidgets('Verify CacheManagerDemoApp renders tabs and controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CacheManagerDemoApp());
    await tester.pump();

    expect(find.text('XueHua Native Cache Manager'), findsOneWidget);
    expect(find.text('Download & Fetch'), findsOneWidget);
    expect(find.text('Cache Browser'), findsOneWidget);
  });
}
