import 'package:flutter_test/flutter_test.dart';
import 'package:theadbook_player/main.dart';

void main() {
	testWidgets('App builds without error', (WidgetTester tester) async {
		await tester.pumpWidget(const TheadbookPlayerApp());
		expect(find.byType(TheadbookPlayerApp), findsOneWidget);
	});
}
