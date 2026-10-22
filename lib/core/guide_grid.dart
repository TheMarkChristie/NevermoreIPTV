/// The guide grid's cursor: which channel row and which moment the remote is on, and the stretch of time the screen
/// shows (two hours, from half an hour ago at the earliest to twelve hours ahead at the latest). Pure, so the remote's
/// moves are tested without a screen.
///
/// Each row is cut into cells: its programmes, and half-hour gaps where the guide has nothing, so Left / Right always
/// move and a row without a guide can still be stepped through.
library;

import 'dart:math';

import 'model.dart';

const gridSpan = 2 * 3600;
const gridBack = 1800;
const gridAhead = 12 * 3600;

int halfHourFloor(int t) => t - t % 1800;

class GridCell {
  const GridCell(this.start, this.stop, this.programme);

  /// Where the cell sits on the grid (clipped to the grid's times; the programme keeps its own).
  final int start;
  final int stop;

  /// Null: no guide information for this half hour.
  final Programme? programme;
}

class GuideGrid {
  GuideGrid({required this.rows, required this.now, int row = 0})
    : minTime = halfHourFloor(now - gridBack),
      maxTime = now + gridAhead {
    this.row = rows.isEmpty ? 0 : row.clamp(0, rows.length - 1);
    time = now;
    windowStart = minTime;
  }

  /// Each row's programmes, sorted.
  final List<List<Programme>> rows;
  final int now;
  final int minTime;
  final int maxTime;
  late int row;

  /// The moment the cursor is on: the cell under it is the focused one.
  late int time;
  late int windowStart;
  final _cells = <int, List<GridCell>>{};

  int get windowEnd => windowStart + gridSpan;

  List<GridCell> cellsOf(int r) => _cells.putIfAbsent(r, () => _build(rows[r]));

  List<GridCell> _build(List<Programme> programmes) {
    final out = <GridCell>[];
    var t = minTime;
    void gapTo(int end) {
      while (t < end) {
        final next = min(end, halfHourFloor(t) + 1800);
        out.add(GridCell(t, next, null));
        t = next;
      }
    }

    for (final p in programmes) {
      if (p.stop <= t) continue;
      if (p.start >= maxTime) break;
      if (p.start > t) gapTo(p.start);
      final s = max(p.start, t);
      final e = min(p.stop, maxTime);
      if (e <= s) continue;
      out.add(GridCell(s, e, p));
      t = e;
    }
    gapTo(maxTime);
    return out;
  }

  int _indexAt(List<GridCell> cells, int t) {
    for (var i = 0; i < cells.length; i++) {
      if (t < cells[i].stop) return i;
    }
    return cells.length - 1;
  }

  GridCell? get cell {
    if (rows.isEmpty) return null;
    final cells = cellsOf(row);
    return cells[_indexAt(cells, time)];
  }

  /// Up a row; false at the top (the categories are above).
  bool up() {
    if (row == 0) return false;
    row--;
    return true;
  }

  void down() {
    if (row < rows.length - 1) row++;
  }

  void pageUp([int n = 6]) => row = max(0, row - n);

  void pageDown([int n = 6]) => row = rows.isEmpty ? 0 : min(rows.length - 1, row + n);

  void right() {
    if (rows.isEmpty) return;
    final cells = cellsOf(row);
    final i = _indexAt(cells, time);
    if (i + 1 < cells.length) time = cells[i + 1].start;
    _keepVisible();
  }

  void left() {
    if (rows.isEmpty) return;
    final cells = cellsOf(row);
    final i = _indexAt(cells, time);
    time = i > 0 ? cells[i - 1].start : minTime;
    _keepVisible();
  }

  /// Puts the cursor on [t] (a search result's programme), with the window moved to show it.
  void focusTime(int t) {
    time = t.clamp(minTime, maxTime - 1);
    _keepVisible();
  }

  void _keepVisible() {
    final latest = max(minTime, maxTime - gridSpan);
    if (time < windowStart) {
      windowStart = halfHourFloor(time).clamp(minTime, latest);
    } else if (time >= windowEnd) {
      windowStart = (halfHourFloor(time) - 1800).clamp(minTime, latest);
    }
  }
}
