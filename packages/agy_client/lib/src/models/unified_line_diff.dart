import 'dart:math' as math;
import 'dart:typed_data';

enum DiffOpKind { context, delete, insert }

class DiffOp {
  const DiffOp(this.kind, this.line);

  final DiffOpKind kind;
  final String line;
}

class UnifiedDiffResult {
  const UnifiedDiffResult({
    required this.diff,
    required this.added,
    required this.removed,
  });

  final String diff;
  final int added;
  final int removed;
}

/// Computes minimal unified line diffs using prefix/suffix trimming, Myers O(ND)
/// edit scripts, and standard 3-line context hunk grouping.
class UnifiedLineDiff {
  UnifiedLineDiff._();

  static List<String> _splitLines(String? text) {
    if (text == null || text.isEmpty) return const <String>[];
    final normalized = text.replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');
    if (lines.length > 1 && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  static List<DiffOp> _fallbackDiff(List<String> a, List<String> b) {
    return <DiffOp>[
      for (final l in a) DiffOp(DiffOpKind.delete, l),
      for (final l in b) DiffOp(DiffOpKind.insert, l),
    ];
  }

  static List<DiffOp> _myersOrFallback(List<String> a, List<String> b) {
    final n = a.length;
    final m = b.length;
    if (n == 0) {
      return [for (final l in b) DiffOp(DiffOpKind.insert, l)];
    }
    if (m == 0) {
      return [for (final l in a) DiffOp(DiffOpKind.delete, l)];
    }
    if (n + m > 40000) {
      return _fallbackDiff(a, b);
    }

    final maxD = math.min(n + m, 1500);
    final offset = maxD;
    final v = Int32List(2 * maxD + 1);
    final trace = <Int32List>[];
    var foundD = -1;

    for (var d = 0; d <= maxD; d++) {
      // Snapshot active diagonal slice [-d..d] before updating for step d.
      final slice = Int32List(2 * d + 1);
      for (var i = 0; i < slice.length; i++) {
        slice[i] = v[offset - d + i];
      }
      trace.add(slice);

      for (var k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
          x = v[offset + k + 1];
        } else {
          x = v[offset + k - 1] + 1;
        }
        var y = x - k;
        while (x < n && y < m && a[x] == b[y]) {
          x++;
          y++;
        }
        v[offset + k] = x;
        if (x >= n && y >= m) {
          foundD = d;
          break;
        }
      }
      if (foundD >= 0) break;
    }

    if (foundD < 0) {
      return _fallbackDiff(a, b);
    }

    final ops = <DiffOp>[];
    var x = n;
    var y = m;
    for (var d = foundD; d > 0; d--) {
      final vPrev = trace[d];
      final k = x - y;
      final prevK = (k == -d ||
              (k != d && vPrev[d + k - 1] < vPrev[d + k + 1]))
          ? k + 1
          : k - 1;
      final prevX = vPrev[d + prevK];
      final prevY = prevX - prevK;
      while (x > prevX && y > prevY) {
        x--;
        y--;
        ops.add(DiffOp(DiffOpKind.context, a[x]));
      }
      if (x == prevX) {
        y--;
        ops.add(DiffOp(DiffOpKind.insert, b[y]));
      } else {
        x--;
        ops.add(DiffOp(DiffOpKind.delete, a[x]));
      }
    }
    while (x > 0 && y > 0) {
      x--;
      y--;
      ops.add(DiffOp(DiffOpKind.context, a[x]));
    }
    return ops.reversed.toList();
  }

  static UnifiedDiffResult compute({
    String? path,
    String? oldText,
    String? newText,
    int contextLines = 3,
    int? maxBodyLines,
  }) {
    final oldLines = _splitLines(oldText);
    final newLines = _splitLines(newText);
    if (oldLines.isEmpty && newLines.isEmpty) {
      return const UnifiedDiffResult(diff: '', added: 0, removed: 0);
    }

    var prefix = 0;
    final minLen = math.min(oldLines.length, newLines.length);
    while (prefix < minLen && oldLines[prefix] == newLines[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < minLen - prefix &&
        oldLines[oldLines.length - 1 - suffix] ==
            newLines[newLines.length - 1 - suffix]) {
      suffix++;
    }

    final midOld = oldLines.sublist(prefix, oldLines.length - suffix);
    final midNew = newLines.sublist(prefix, newLines.length - suffix);
    if (midOld.isEmpty && midNew.isEmpty) {
      return const UnifiedDiffResult(diff: '', added: 0, removed: 0);
    }

    final midOps = _myersOrFallback(midOld, midNew);
    var added = 0;
    var removed = 0;
    for (final op in midOps) {
      if (op.kind == DiffOpKind.insert) {
        added++;
      } else if (op.kind == DiffOpKind.delete) {
        removed++;
      }
    }
    if (added == 0 && removed == 0) {
      return const UnifiedDiffResult(diff: '', added: 0, removed: 0);
    }

    final leadCount = math.min(contextLines, prefix);
    final trailCount = math.min(contextLines, suffix);
    final suffixStart = oldLines.length - suffix;
    final windowOps = <DiffOp>[
      for (var i = prefix - leadCount; i < prefix; i++)
        DiffOp(DiffOpKind.context, oldLines[i]),
      ...midOps,
      for (var i = suffixStart; i < suffixStart + trailCount; i++)
        DiffOp(DiffOpKind.context, oldLines[i]),
    ];

    final baseOldLine = prefix - leadCount + 1;
    final baseNewLine = prefix - leadCount + 1;
    final oldPos = List<int>.filled(windowOps.length, 0);
    final newPos = List<int>.filled(windowOps.length, 0);
    final editIndices = <int>[];
    var curOld = baseOldLine;
    var curNew = baseNewLine;
    for (var i = 0; i < windowOps.length; i++) {
      oldPos[i] = curOld;
      newPos[i] = curNew;
      switch (windowOps[i].kind) {
        case DiffOpKind.context:
          curOld++;
          curNew++;
        case DiffOpKind.delete:
          curOld++;
          editIndices.add(i);
        case DiffOpKind.insert:
          curNew++;
          editIndices.add(i);
      }
    }

    if (editIndices.isEmpty) {
      return const UnifiedDiffResult(diff: '', added: 0, removed: 0);
    }

    final outLines = <String>[];
    if (path != null && path.isNotEmpty) {
      outLines.add(oldLines.isEmpty ? '--- /dev/null' : '--- a/$path');
      outLines.add(newLines.isEmpty ? '+++ /dev/null' : '+++ b/$path');
    }

    var bodyCount = 0;
    var truncated = 0;
    void appendHunk(int startEdit, int endEdit) {
      final hStart = math.max(0, startEdit - contextLines);
      final hEnd = math.min(windowOps.length, endEdit + contextLines + 1);
      var hOldCount = 0;
      var hNewCount = 0;
      for (var i = hStart; i < hEnd; i++) {
        switch (windowOps[i].kind) {
          case DiffOpKind.context:
            hOldCount++;
            hNewCount++;
          case DiffOpKind.delete:
            hOldCount++;
          case DiffOpKind.insert:
            hNewCount++;
        }
      }
      final hOldStart = hOldCount == 0 ? oldPos[hStart] - 1 : oldPos[hStart];
      final hNewStart = hNewCount == 0 ? newPos[hStart] - 1 : newPos[hStart];
      if (maxBodyLines == null || bodyCount < maxBodyLines) {
        outLines.add('@@ -$hOldStart,$hOldCount +$hNewStart,$hNewCount @@');
      }
      for (var i = hStart; i < hEnd; i++) {
        if (maxBodyLines != null && bodyCount >= maxBodyLines) {
          truncated++;
          continue;
        }
        final op = windowOps[i];
        final prefixChar = switch (op.kind) {
          DiffOpKind.context => ' ',
          DiffOpKind.delete => '-',
          DiffOpKind.insert => '+',
        };
        outLines.add('$prefixChar${op.line}');
        bodyCount++;
      }
    }

    var groupStart = editIndices.first;
    var groupEnd = editIndices.first;
    for (var i = 1; i < editIndices.length; i++) {
      final idx = editIndices[i];
      if (idx - groupEnd - 1 <= contextLines * 2) {
        groupEnd = idx;
      } else {
        appendHunk(groupStart, groupEnd);
        groupStart = idx;
        groupEnd = idx;
      }
    }
    appendHunk(groupStart, groupEnd);

    if (truncated > 0) {
      outLines.add(' ... ($truncated more)');
    }

    return UnifiedDiffResult(
      diff: outLines.join('\n'),
      added: added,
      removed: removed,
    );
  }
}
