// The guide grid's cursor, moved as the remote would. Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/guide_grid.dart';
import 'package:nevermore_iptv/core/model.dart';

// 16:10 on some day (epoch seconds on a half-hour boundary plus ten minutes)
const now = 1800 * 1000000 + 600;

Programme p(int startMin, int stopMin, String title) => Programme(now + startMin * 60, now + stopMin * 60, title);

void main() {
  final rows = [
    [p(-70, -10, 'Before'), p(-10, 50, 'On now'), p(50, 80, 'Next'), p(80, 300, 'Film')],
    <Programme>[], // a channel with no guide
    [p(-40, 20, 'Long'), p(20, 140, 'Later')],
  ];

  test('cells cover the grid from half an hour back, gaps in half hours', () {
    final g = GuideGrid(rows: rows, now: now);
    final cells = g.cellsOf(0);
    expect(cells.first.start, g.minTime);
    expect(g.minTime, halfHourFloor(now - 1800));
    expect(cells.where((c) => c.programme != null).map((c) => c.programme!.title), [
      'Before',
      'On now',
      'Next',
      'Film',
    ]);
    expect(cells.last.stop, g.maxTime);
    final empty = g.cellsOf(1);
    expect(empty.every((c) => c.programme == null && c.stop - c.start <= 1800), isTrue);
    expect(empty.first.start, g.minTime);
    expect(empty.last.stop, g.maxTime);
  });

  test('opens on the programme on now', () {
    final g = GuideGrid(rows: rows, now: now);
    expect(g.cell!.programme!.title, 'On now');
  });

  test('right and left move a programme at a time', () {
    final g = GuideGrid(rows: rows, now: now);
    g.right();
    expect(g.cell!.programme!.title, 'Next');
    g.right();
    expect(g.cell!.programme!.title, 'Film');
    g.left();
    g.left();
    expect(g.cell!.programme!.title, 'On now');
    g.left();
    expect(g.cell!.programme!.title, 'Before');
    g.left();
    expect(g.time, g.minTime); // stays at the start of the grid
  });

  test('up and down keep the moment; up from the top leaves the grid', () {
    final g = GuideGrid(rows: rows, now: now);
    g.down();
    expect(g.cell!.programme, isNull); // no guide on this channel
    g.down();
    expect(g.cell!.programme!.title, 'Long');
    g.down();
    expect(g.row, 2); // stays on the last row
    g.up();
    g.up();
    expect(g.up(), isFalse);
    expect(g.row, 0);
  });

  test('a row without a guide still steps through time', () {
    final g = GuideGrid(rows: rows, now: now, row: 1);
    final before = g.time;
    g.right();
    expect(g.time, greaterThan(before));
    expect(g.time - before, lessThanOrEqualTo(1800));
  });

  test('the window follows the cursor and stays within its limits', () {
    final g = GuideGrid(rows: rows, now: now);
    expect(g.windowStart, g.minTime);
    g.right();
    g.right(); // Film, at +80 min: still inside two hours from the start of the window
    expect(g.time < g.windowEnd, isTrue);
    for (var i = 0; i < 40; i++) {
      g.right();
    }
    expect(g.windowEnd, lessThanOrEqualTo(g.maxTime));
    expect(g.time >= g.windowStart && g.time < g.windowEnd, isTrue);
    for (var i = 0; i < 60; i++) {
      g.left();
    }
    expect(g.windowStart, g.minTime);
  });

  test('page up and down', () {
    final many = List.generate(20, (_) => <Programme>[]);
    final g = GuideGrid(rows: many, now: now, row: 10);
    g.pageDown();
    expect(g.row, 16);
    g.pageDown();
    expect(g.row, 19);
    g.pageUp();
    g.pageUp();
    g.pageUp();
    g.pageUp();
    expect(g.row, 0);
  });
}
