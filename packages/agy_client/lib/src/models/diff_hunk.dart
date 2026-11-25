/// Status of an individual diff hunk during mobile-first swipe review.
enum DiffHunkStatus {
  pending,
  accepted,
  rejected,
}

/// Classification for a single rendered row inside a GitHub-style diff viewer.
enum DiffRowKind {
  hunkHeader,
  context,
  addition,
  deletion,
}

/// A line-numbered row in a GitHub-style unified diff view.
class DiffLineRow {
  const DiffLineRow({
    required this.kind,
    required this.text,
    required this.rawLine,
    this.oldLineNumber,
    this.newLineNumber,
  });

  final DiffRowKind kind;
  final String text;
  final String rawLine;
  final int? oldLineNumber;
  final int? newLineNumber;
}

/// A left/right row pair for GitHub-style Split (side-by-side) diff rendering.
class DiffSplitPair {
  const DiffSplitPair({
    this.left,
    this.right,
    this.hunkHeaderText,
  });

  final DiffLineRow? left;
  final DiffLineRow? right;
  final String? hunkHeaderText;

  bool get isHunkHeader => hunkHeaderText != null;
}

/// 5-block GitHub PR diffstat indicator (`green` additions, `red` deletions, `neutral`).
class DiffStatBlocks {
  const DiffStatBlocks({
    required this.addedBlocks,
    required this.removedBlocks,
    required this.neutralBlocks,
  });

  final int addedBlocks;
  final int removedBlocks;
  final int neutralBlocks;

  static DiffStatBlocks compute(int added, int removed, {int totalBlocks = 5}) {
    final total = added + removed;
    if (total <= 0) {
      return DiffStatBlocks(
        addedBlocks: 0,
        removedBlocks: 0,
        neutralBlocks: totalBlocks,
      );
    }
    var g = ((added / total) * totalBlocks).round();
    var r = ((removed / total) * totalBlocks).round();
    if (added > 0 && g == 0) g = 1;
    if (removed > 0 && r == 0) r = 1;
    while (g + r > totalBlocks) {
      if (g >= r && g > 0) {
        g--;
      } else if (r > 0) {
        r--;
      }
    }
    return DiffStatBlocks(
      addedBlocks: g,
      removedBlocks: r,
      neutralBlocks: (totalBlocks - g - r).clamp(0, totalBlocks),
    );
  }
}

/// A single unified diff hunk within a modified file.
class DiffHunk {
  const DiffHunk({
    required this.id,
    required this.filePath,
    required this.header,
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
    this.status = DiffHunkStatus.pending,
    this.oldPath,
    this.newPath,
  });

  final String id;
  final String filePath;
  final String header;
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> lines;
  final DiffHunkStatus status;
  final String? oldPath;
  final String? newPath;

  int get addedLines =>
      lines.where((l) => l.startsWith('+') && !l.startsWith('+++')).length;

  int get removedLines =>
      lines.where((l) => l.startsWith('-') && !l.startsWith('---')).length;

  DiffHunk copyWith({DiffHunkStatus? status}) {
    return DiffHunk(
      id: id,
      filePath: filePath,
      header: header,
      oldStart: oldStart,
      oldCount: oldCount,
      newStart: newStart,
      newCount: newCount,
      lines: lines,
      status: status ?? this.status,
      oldPath: oldPath,
      newPath: newPath,
    );
  }

  /// Generates a standalone single-hunk unified patch usable by `git apply`.
  String toSingleHunkPatch() {
    final aPath = oldPath ?? 'a/$filePath';
    final bPath = newPath ?? 'b/$filePath';
    final buf = StringBuffer()
      ..writeln('--- $aPath')
      ..writeln('+++ $bPath')
      ..writeln(header);
    for (final line in lines) {
      buf.writeln(line);
    }
    return buf.toString();
  }

  /// Produces line-numbered [DiffLineRow] entries for GitHub-style unified rendering.
  List<DiffLineRow> toNumberedRows() {
    final rows = <DiffLineRow>[
      DiffLineRow(
        kind: DiffRowKind.hunkHeader,
        text: header,
        rawLine: header,
      ),
    ];
    var oldLine = oldStart;
    var newLine = newStart;
    for (final line in lines) {
      if (line.startsWith(r'\')) continue;
      if (line.startsWith('+')) {
        rows.add(
          DiffLineRow(
            kind: DiffRowKind.addition,
            text: line.substring(1),
            rawLine: line,
            newLineNumber: newLine++,
          ),
        );
      } else if (line.startsWith('-')) {
        rows.add(
          DiffLineRow(
            kind: DiffRowKind.deletion,
            text: line.substring(1),
            rawLine: line,
            oldLineNumber: oldLine++,
          ),
        );
      } else {
        final content = line.startsWith(' ') ? line.substring(1) : line;
        rows.add(
          DiffLineRow(
            kind: DiffRowKind.context,
            text: content,
            rawLine: line,
            oldLineNumber: oldLine++,
            newLineNumber: newLine++,
          ),
        );
      }
    }
    return rows;
  }

  /// Pairs consecutive deletions and additions into side-by-side [DiffSplitPair] rows.
  List<DiffSplitPair> toSplitPairs() {
    final numbered = toNumberedRows();
    final pairs = <DiffSplitPair>[];
    var i = 0;
    while (i < numbered.length) {
      final row = numbered[i];
      if (row.kind == DiffRowKind.hunkHeader) {
        pairs.add(DiffSplitPair(hunkHeaderText: row.text));
        i++;
        continue;
      }
      if (row.kind == DiffRowKind.context) {
        pairs.add(DiffSplitPair(left: row, right: row));
        i++;
        continue;
      }
      final dels = <DiffLineRow>[];
      while (i < numbered.length && numbered[i].kind == DiffRowKind.deletion) {
        dels.add(numbered[i]);
        i++;
      }
      final adds = <DiffLineRow>[];
      while (i < numbered.length && numbered[i].kind == DiffRowKind.addition) {
        adds.add(numbered[i]);
        i++;
      }
      final maxLen = dels.length > adds.length ? dels.length : adds.length;
      for (var k = 0; k < maxLen; k++) {
        pairs.add(
          DiffSplitPair(
            left: k < dels.length ? dels[k] : null,
            right: k < adds.length ? adds[k] : null,
          ),
        );
      }
    }
    return pairs;
  }
}

/// Parsed file grouping of unified diff hunks.
class DiffFileHunks {
  const DiffFileHunks({
    required this.filePath,
    required this.hunks,
  });

  final String filePath;
  final List<DiffHunk> hunks;
}

/// Parses raw `git diff` unified output into per-file [DiffHunk] objects and
/// supports pure-Dart hunk reversion when rejecting a change on mobile.
class DiffHunkParser {
  const DiffHunkParser._();

  static final RegExp _hunkHeaderRe = RegExp(
    r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$',
  );

  static List<DiffFileHunks> parse(String unifiedDiff) {
    if (unifiedDiff.trim().isEmpty) return const [];
    final rawLines = unifiedDiff.replaceAll('\r\n', '\n').split('\n');

    final files = <DiffFileHunks>[];
    String? currentPath;
    String? currentOldHeader;
    String? currentNewHeader;
    var hunks = <DiffHunk>[];

    String? hunkHeader;
    int oldStart = 0;
    int oldCount = 0;
    int newStart = 0;
    int newCount = 0;
    var hunkLines = <String>[];

    void flushHunk() {
      if (hunkHeader == null || currentPath == null) return;
      final id = '$currentPath#${hunks.length}@$oldStart:$newStart';
      hunks.add(
        DiffHunk(
          id: id,
          filePath: currentPath,
          header: hunkHeader!,
          oldStart: oldStart,
          oldCount: oldCount,
          newStart: newStart,
          newCount: newCount,
          lines: List.unmodifiable(hunkLines),
          oldPath: currentOldHeader,
          newPath: currentNewHeader,
        ),
      );
      hunkHeader = null;
      hunkLines = <String>[];
    }

    void flushFile() {
      flushHunk();
      if (currentPath != null && hunks.isNotEmpty) {
        files.add(
          DiffFileHunks(
            filePath: currentPath,
            hunks: List.unmodifiable(hunks),
          ),
        );
      }
      hunks = <DiffHunk>[];
      currentOldHeader = null;
      currentNewHeader = null;
    }

    for (final line in rawLines) {
      if (line.startsWith('diff --git ')) {
        flushFile();
        final match = RegExp(r'^diff --git a/(.+?) b/(.+)$').firstMatch(line);
        if (match != null) {
          currentPath = match.group(2)?.trim();
        } else {
          final parts = line.split(' ');
          if (parts.length >= 4) {
            currentPath = parts.last.replaceFirst(RegExp(r'^[ab]/'), '').trim();
          }
        }
        continue;
      }
      if (line.startsWith('--- ')) {
        currentOldHeader = line.substring(4).trim();
        if (currentPath == null &&
            currentOldHeader != null &&
            currentOldHeader != '/dev/null') {
          currentPath = currentOldHeader!.replaceFirst(RegExp(r'^a/'), '');
        }
        continue;
      }
      if (line.startsWith('+++ ')) {
        currentNewHeader = line.substring(4).trim();
        if (currentNewHeader != null && currentNewHeader != '/dev/null') {
          currentPath = currentNewHeader!.replaceFirst(RegExp(r'^b/'), '');
        }
        continue;
      }
      final hm = _hunkHeaderRe.firstMatch(line);
      if (hm != null) {
        flushHunk();
        hunkHeader = line;
        oldStart = int.parse(hm.group(1)!);
        oldCount = hm.group(2) != null ? int.parse(hm.group(2)!) : 1;
        newStart = int.parse(hm.group(3)!);
        newCount = hm.group(4) != null ? int.parse(hm.group(4)!) : 1;
        continue;
      }
      if (hunkHeader != null &&
          (line.startsWith(' ') ||
              line.startsWith('+') ||
              line.startsWith('-') ||
              line.startsWith(r'\'))) {
        hunkLines.add(line);
      }
    }
    flushFile();
    return files;
  }

  /// Pure-Dart reverse application of a single [DiffHunk] against [fileContent].
  /// Returns `null` if the hunk cannot be cleanly matched in [fileContent].
  static String? revertHunkInContent(String fileContent, DiffHunk hunk) {
    final normalized = fileContent.replaceAll('\r\n', '\n');
    final hadTrailingNewline = normalized.endsWith('\n');
    final docLines = normalized.split('\n');
    if (hadTrailingNewline && docLines.isNotEmpty && docLines.last.isEmpty) {
      docLines.removeLast();
    }

    // Expected lines currently in the new file (context + added lines),
    // and replacement lines from the old file (context + removed lines).
    final expectedNew = <String>[];
    final replacementOld = <String>[];
    for (final line in hunk.lines) {
      if (line.startsWith(r'\')) continue;
      if (line.startsWith('+')) {
        expectedNew.add(line.substring(1));
      } else if (line.startsWith('-')) {
        replacementOld.add(line.substring(1));
      } else if (line.startsWith(' ')) {
        final content = line.substring(1);
        expectedNew.add(content);
        replacementOld.add(content);
      }
    }

    if (expectedNew.isEmpty) {
      // Pure deletion hunk: insert removed lines back around newStart.
      final insertIdx = hunk.newStart.clamp(0, docLines.length);
      final updated = <String>[
        ...docLines.sublist(0, insertIdx),
        ...replacementOld,
        ...docLines.sublist(insertIdx),
      ];
      return _joinLines(updated, trailingNewline: hadTrailingNewline);
    }

    final preferredIdx = (hunk.newStart - 1).clamp(0, docLines.length);
    final matchIdx = _findSublistIndex(docLines, expectedNew, preferredIdx);
    if (matchIdx < 0) return null;

    final updated = <String>[
      ...docLines.sublist(0, matchIdx),
      ...replacementOld,
      ...docLines.sublist(matchIdx + expectedNew.length),
    ];
    return _joinLines(
      updated,
      trailingNewline: hadTrailingNewline || updated.isNotEmpty,
    );
  }

  static int _findSublistIndex(
    List<String> haystack,
    List<String> needle,
    int preferredStart,
  ) {
    if (needle.length > haystack.length) return -1;
    bool matchesAt(int idx) {
      if (idx < 0 || idx + needle.length > haystack.length) return false;
      for (var i = 0; i < needle.length; i++) {
        if (haystack[idx + i] != needle[i]) return false;
      }
      return true;
    }

    if (matchesAt(preferredStart)) return preferredStart;
    for (var offset = 1; offset <= haystack.length; offset++) {
      if (matchesAt(preferredStart - offset)) return preferredStart - offset;
      if (matchesAt(preferredStart + offset)) return preferredStart + offset;
    }
    return -1;
  }

  static String _joinLines(List<String> lines, {required bool trailingNewline}) {
    if (lines.isEmpty) return '';
    final joined = lines.join('\n');
    return trailingNewline ? '$joined\n' : joined;
  }
}
