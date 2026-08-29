import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mf4_viewer/main.dart';

void main() {
  testWidgets('shows welcome screen with open-file action', (tester) async {
    await tester.pumpWidget(const Mf4ViewerApp());
    expect(find.text('Open MF4 file(s)'), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsWidgets);
  });
}
