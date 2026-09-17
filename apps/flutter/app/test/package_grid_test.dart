import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/features/packages/components/PackageGrid.dart';

/// Verifies package grids build lazily and isolate card updates while scrolling.
void main() {
  testWidgets('scrolling does not rebuild cards already in the viewport', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final builds = List<int>.filled(1000, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: <Widget>[
              PackageSliverList(
                itemCount: builds.length,
                itemBuilder: (context, index) {
                  builds[index]++;
                  return SizedBox(height: 100, child: Text('Package $index'));
                },
              ),
            ],
          ),
        ),
      ),
    );
    final initialBuilds = builds[2];
    expect(initialBuilds, greaterThan(0));
    expect(builds.where((count) => count > 0).length, lessThan(30));

    for (var step = 1; step <= 10; step++) {
      controller.jumpTo(step * 5);
      await tester.pump();
    }
    expect(builds[2], initialBuilds);
    expect(builds.where((count) => count > 0).length, lessThan(30));
  });

  testWidgets('repainting one card does not repaint its row neighbor', (
    tester,
  ) async {
    final repaint = ChangeNotifier();
    addTearDown(repaint.dispose);
    final paints = List<int>.filled(2, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: <Widget>[
              PackageSliverList(
                itemCount: 2,
                itemBuilder: (context, index) => SizedBox(
                  height: 100,
                  child: CustomPaint(
                    painter: _PaintCounter(
                      onPaint: () => paints[index]++,
                      repaint: index == 0 ? repaint : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final initialPaints = List<int>.of(paints);
    repaint.notifyListeners();
    await tester.pump();

    expect(paints[0], greaterThan(initialPaints[0]));
    expect(paints[1], initialPaints[1]);
  });

  testWidgets('width changes reflow the grid without rebuilding its parent', (
    tester,
  ) async {
    final width = ValueNotifier<double>(800);
    addTearDown(width.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<double>(
            valueListenable: width,
            builder: (context, value, child) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: value, child: child),
            ),
            child: CustomScrollView(
              slivers: <Widget>[
                PackageSliverList(
                  itemCount: 3,
                  itemBuilder: (context, index) => SizedBox(
                    key: ValueKey<int>(index),
                    height: 100,
                    child: Text('Package $index'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final first = find.byKey(const ValueKey<int>(0));
    final second = find.byKey(const ValueKey<int>(1));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(tester.getSize(first).width, 394);

    width.value = 700;
    await tester.pump();
    expect(tester.getSize(first).width, 344);
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);

    width.value = 400;
    await tester.pump();
    expect(tester.getSize(first).width, 400);
    expect(tester.getTopLeft(second).dy - tester.getTopLeft(first).dy, 100);
    expect(find.text('Package 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('parent data updates refresh cards at the same width', (
    tester,
  ) async {
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: revision,
            builder: (context, value, child) => CustomScrollView(
              slivers: <Widget>[
                PackageSliverList(
                  itemCount: value + 1,
                  itemBuilder: (context, index) => SizedBox(
                    height: 100,
                    child: Text('Revision $value package $index'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Revision 0 package 0'), findsOneWidget);
    revision.value = 1;
    await tester.pump();
    expect(find.text('Revision 0 package 0'), findsNothing);
    expect(find.text('Revision 1 package 0'), findsOneWidget);
    expect(find.text('Revision 1 package 1'), findsOneWidget);
  });

  testWidgets('expanding a card moves the following row without overlap', (
    tester,
  ) async {
    final height = ValueNotifier<double>(100);
    addTearDown(height.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: <Widget>[
              PackageSliverList(
                itemCount: 3,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ValueListenableBuilder<double>(
                      valueListenable: height,
                      builder: (context, value, child) => AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        child: SizedBox(
                          key: const ValueKey<int>(0),
                          height: value,
                        ),
                      ),
                    );
                  }
                  return SizedBox(key: ValueKey<int>(index), height: 100);
                },
              ),
            ],
          ),
        ),
      ),
    );
    final first = find.byKey(const ValueKey<int>(0));
    final neighbor = find.byKey(const ValueKey<int>(1));
    final nextRow = find.byKey(const ValueKey<int>(2));
    expect(tester.getTopLeft(nextRow).dy, tester.getBottomLeft(first).dy);

    height.value = 180;
    await tester.pumpAndSettle();
    expect(tester.getSize(first).height, 180);
    expect(tester.getSize(neighbor).height, 100);
    expect(tester.getTopLeft(neighbor).dy, tester.getTopLeft(first).dy);
    expect(tester.getTopLeft(nextRow).dy, tester.getBottomLeft(first).dy);
    expect(tester.takeException(), isNull);
  });
}

class _PaintCounter extends CustomPainter {
  /// Counts paints triggered by a card-local animation or state update.
  _PaintCounter({required this.onPaint, super.repaint});

  final VoidCallback onPaint;

  /// Records one paint and draws a visible card surface.
  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  /// Repaints when the test installs a new counter.
  @override
  bool shouldRepaint(covariant _PaintCounter oldDelegate) => true;
}
