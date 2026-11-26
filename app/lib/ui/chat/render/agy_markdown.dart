import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../state/projects_state.dart';
import '../../../state/runtime_state.dart';
import '../../../state/session_export_helper.dart';
import '../../../theme/app_theme.dart';

/// Modeled on DSH-Go's `stream_repair.dart`: closes unfinished inline delimiters
/// (`**`, `*`, `~~`, `` ` ``) at the end of a streaming reply so partial Markdown
/// never flickers or falls back to raw symbols.
final RegExp _streamingFenceRegex = RegExp(r'^```', multiLine: true);
final RegExp _pathSplitRegex = RegExp(r'[/\\]');
final RegExp _whitespaceSplitRegex = RegExp(r'\s+');

String repairStreamingMarkdown(String text) {
  if (text.isEmpty) return text;
  // Don't modify inside an unclosed fenced code block.
  final fenceMatches = _streamingFenceRegex.allMatches(text).length;
  if (fenceMatches.isOdd) return text;

  final lastNewline = text.lastIndexOf('\n');
  final tail = lastNewline >= 0 ? text.substring(lastNewline + 1) : text;
  final prefix = lastNewline >= 0 ? text.substring(0, lastNewline + 1) : '';

  var repaired = tail;
  if ('`'.allMatches(repaired).length.isOdd) {
    repaired = '$repaired`';
  }
  if ('**'.allMatches(repaired).length.isOdd) {
    repaired = '$repaired**';
  }
  if ('~~'.allMatches(repaired).length.isOdd) {
    repaired = '$repaired~~';
  }
  return '$prefix$repaired';
}

class _MarkdownThemeCacheKey {
  const _MarkdownThemeCacheKey({
    required this.brightness,
    required this.primary,
    required this.outlineVariant,
    required this.inlineCodeFg,
    required this.inlineCodeBg,
    required this.codeWellBorder,
    required this.quoteBar,
    required this.quoteText,
    required this.textPrimary,
    required this.textSecondary,
    required this.info,
    required this.success,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.danger,
    required this.tableBorder,
    required this.tableHeaderBg,
    required this.tableStripeBg,
    required this.secondary,
  });

  final Brightness brightness;
  final Color primary;
  final Color outlineVariant;
  final Color inlineCodeFg;
  final Color inlineCodeBg;
  final Color codeWellBorder;
  final Color quoteBar;
  final Color quoteText;
  final Color textPrimary;
  final Color textSecondary;
  final Color info;
  final Color success;
  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;
  final Color danger;
  final Color tableBorder;
  final Color tableHeaderBg;
  final Color tableStripeBg;
  final bool secondary;

  @override
  bool operator ==(Object other) =>
      other is _MarkdownThemeCacheKey &&
      other.brightness == brightness &&
      other.primary == primary &&
      other.outlineVariant == outlineVariant &&
      other.inlineCodeFg == inlineCodeFg &&
      other.inlineCodeBg == inlineCodeBg &&
      other.codeWellBorder == codeWellBorder &&
      other.quoteBar == quoteBar &&
      other.quoteText == quoteText &&
      other.textPrimary == textPrimary &&
      other.textSecondary == textSecondary &&
      other.info == info &&
      other.success == success &&
      other.warning == warning &&
      other.warningContainer == warningContainer &&
      other.onWarningContainer == onWarningContainer &&
      other.danger == danger &&
      other.tableBorder == tableBorder &&
      other.tableHeaderBg == tableHeaderBg &&
      other.tableStripeBg == tableStripeBg &&
      other.secondary == secondary;

  @override
  int get hashCode => Object.hash(
        brightness,
        primary,
        outlineVariant,
        inlineCodeFg,
        inlineCodeBg,
        codeWellBorder,
        quoteBar,
        quoteText,
        textPrimary,
        textSecondary,
        info,
        success,
        warning,
        warningContainer,
        onWarningContainer,
        danger,
        tableBorder,
        tableHeaderBg,
        tableStripeBg,
        secondary,
      );
}

/// High-contrast, dark-mode-safe Markdown renderer modeled on DSH-Go's `MarkdownBody`.
class AgyMarkdown extends StatelessWidget {
  const AgyMarkdown({
    super.key,
    required this.text,
    this.streaming = false,
    this.secondary = false,
    this.selectable = true,
  });

  final String text;
  final bool streaming;
  final bool secondary;
  final bool selectable;

  static final Map<_MarkdownThemeCacheKey, GptMarkdownThemeData> _themeCache =
      <_MarkdownThemeCacheKey, GptMarkdownThemeData>{};

  static GptMarkdownThemeData _resolveTheme(
    ThemeData theme,
    ColorScheme colors,
    AgySemanticColors semantic,
    Color baseColor,
    bool secondary,
  ) {
    final key = _MarkdownThemeCacheKey(
      brightness: theme.brightness,
      primary: colors.primary,
      outlineVariant: colors.outlineVariant,
      inlineCodeFg: semantic.inlineCodeFg,
      inlineCodeBg: semantic.inlineCodeBg,
      codeWellBorder: semantic.codeWellBorder,
      quoteBar: semantic.quoteBar,
      quoteText: semantic.quoteText,
      textPrimary: semantic.textPrimary,
      textSecondary: semantic.textSecondary,
      info: semantic.info,
      success: semantic.success,
      warning: semantic.warning,
      warningContainer: semantic.warningContainer,
      onWarningContainer: semantic.onWarningContainer,
      danger: semantic.danger,
      tableBorder: semantic.tableBorder,
      tableHeaderBg: semantic.tableHeaderBg,
      tableStripeBg: semantic.tableStripeBg,
      secondary: secondary,
    );
    final cached = _themeCache[key];
    if (cached != null) return cached;

    TextStyle heading(double size, {double height = 1.4}) => TextStyle(
          fontSize: secondary ? size * 0.9 : size,
          fontWeight: FontWeight.w700,
          height: height,
          color: baseColor,
          leadingDistribution: TextLeadingDistribution.even,
        );

    final built = GptMarkdownThemeData(
      brightness: theme.brightness,
      h1: heading(20),
      h2: heading(18),
      h3: heading(16.5),
      h4: heading(15.5),
      h5: heading(15),
      h6: heading(14.5),
      hrLineThickness: 0.75,
      hrLineColor: colors.outlineVariant,
      hrLinePadding: const EdgeInsets.symmetric(vertical: 12),
      linkColor: colors.primary,
      linkHoverColor: colors.primary,
      autoAddDividerLineAfterH1: false,
      inlineCode: InlineCodeStyle(
        fontFamily: 'monospace',
        fontSizeFactor: 0.88,
        color: semantic.inlineCodeFg,
        backgroundColor: semantic.inlineCodeBg,
        borderColor: semantic.codeWellBorder,
        borderWidth: 0.5,
        borderRadius: const Radius.circular(6),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      ),
      styleSheet: GptMarkdownStyleSheet(
        blockQuote: BlockQuoteStyle(
          barWidth: 3,
          barColor: semantic.quoteBar,
          barRadius: const Radius.circular(2),
          textStyle: TextStyle(color: semantic.quoteText),
        ),
        list: ListStyle(
          bulletColor: semantic.textSecondary,
          bulletSize: 5,
          markerTextStyle: TextStyle(color: semantic.textSecondary),
        ),
        alert: AlertStyle(
          borderRadius: const Radius.circular(10),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 14, 10),
          margin: EdgeInsets.zero,
          titleStyle: TextStyle(
            fontWeight: FontWeight.w700,
            color: semantic.textPrimary,
          ),
          titleGap: 4,
          note: AlertStyle(title: 'Note', color: semantic.info, icon: Icons.info_outline),
          tip: AlertStyle(title: 'Tip', color: semantic.success, icon: Icons.lightbulb_outline),
          important: AlertStyle(title: 'Important', color: colors.primary, icon: Icons.priority_high),
          warning: AlertStyle(title: 'Warning', color: semantic.warning, icon: Icons.warning_amber_rounded),
          caution: AlertStyle(title: 'Caution', color: semantic.danger, icon: Icons.error_outline),
        ),
        highlight: HighlightStyle(
          backgroundColor: semantic.warningContainer,
          color: semantic.onWarningContainer,
        ),
        link: LinkStyle(
          color: colors.primary,
          hoverColor: colors.primary,
          decoration: TextDecoration.underline,
          decorationThickness: 0.7,
        ),
        hr: HrStyle(thickness: 0.75, color: colors.outlineVariant),
        table: TableStyle(
          borderColor: semantic.tableBorder,
          borderWidth: 0.75,
          borderRadius: Radius.zero,
          headerBackground: semantic.tableHeaderBg,
          rowStripeColor: semantic.tableStripeBg,
          cellPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          columnWidth: const MinColumnWidth(
            IntrinsicColumnWidth(),
            FixedColumnWidth(260),
          ),
          overflow: TableOverflow.scroll,
        ),
      ),
    );
    if (_themeCache.length >= 8) {
      _themeCache.clear();
    }
    _themeCache[key] = built;
    return built;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final semantic = AgySemanticColors.of(context);

    final baseColor = secondary ? semantic.textSecondary : semantic.textPrimary;
    final bodyStyle = TextStyle(
      color: baseColor,
      fontSize: secondary ? 13.5 : 15.0,
      height: 1.5,
      leadingDistribution: TextLeadingDistribution.even,
    );

    final source = streaming ? repairStreamingMarkdown(text) : text;
    final gptTheme = _resolveTheme(theme, colors, semantic, baseColor, secondary);

    Widget content = GptMarkdownTheme(
      gptThemeData: gptTheme,
      child: DefaultTextStyle.merge(
        style: bodyStyle,
        child: GptMarkdown(
          source,
          style: bodyStyle,
          followLinkColor: false,
          onLinkTap: (url, _) {
            final uri = Uri.tryParse(url.trim());
            if (uri != null &&
                (uri.scheme == 'http' ||
                    uri.scheme == 'https' ||
                    uri.scheme == 'mailto')) {
              launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          checkboxBuilder: (context, checked, child, style) => Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
                color: checked ? colors.primary : semantic.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(child: child),
            ],
          ),
          codeBuilder: (context, name, code, closed) => _AgyCodeBlock(
            language: name.trim(),
            code: code,
          ),
        ),
      ),
    );

    if (selectable && !streaming) {
      content = SelectionArea(child: content);
    }
    return content;
  }
}

class _AgyCodeBlock extends StatelessWidget {
  const _AgyCodeBlock({
    required this.language,
    required this.code,
  });

  final String language;
  final String code;

  static String _extensionFor(String lang) {
    final normalized = lang.trim().toLowerCase();
    return switch (normalized) {
      'dart' => 'dart',
      'kotlin' || 'kt' => 'kt',
      'python' || 'py' => 'py',
      'javascript' || 'js' => 'js',
      'typescript' || 'ts' => 'ts',
      'json' => 'json',
      'yaml' || 'yml' => 'yaml',
      'bash' || 'sh' || 'zsh' => 'sh',
      'markdown' || 'md' => 'md',
      'xml' || 'html' => normalized,
      'sql' => 'sql',
      'rust' || 'rs' => 'rs',
      'go' => 'go',
      _ => 'txt',
    };
  }

  Future<void> _saveToFile(BuildContext context) async {
    var baseDir = '';
    try {
      final container = ProviderScope.containerOf(context, listen: false);
      final projDir =
          container.read(projectsProvider).activeProject.primaryFolder;
      final wsDir = container.read(runtimeProvider).status.workspaceRoot ?? '';
      baseDir = projDir.isNotEmpty ? projDir : wsDir;
    } catch (_) {
      // Allows widget testing without ProviderScope.
    }
    final ext = _extensionFor(language);
    final suggested =
        baseDir.isNotEmpty ? '$baseDir/snippet.$ext' : 'snippet.$ext';
    final ctrl = TextEditingController(text: suggested);
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Code Block'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Destination file path or filename',
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (chosen == null || chosen.isEmpty || !context.mounted) return;

    var savedNotice = '';
    final isPath = chosen.contains('/') || chosen.contains('\\');
    if (isPath) {
      final target = File(chosen);
      if (await target.exists()) {
        if (!context.mounted) return;
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Overwrite existing file?'),
            content: Text('$chosen already exists.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Overwrite'),
              ),
            ],
          ),
        );
        if (overwrite != true) return;
      }
      try {
        await target.parent.create(recursive: true);
        await target.writeAsString(code);
        savedNotice = 'Saved to $chosen';
      } catch (_) {
        final name = chosen.split(_pathSplitRegex).last;
        final dl = await SessionExportHelper.saveTextToDownloads(
          filename: name,
          content: code,
          mimeType: 'text/plain',
        );
        savedNotice =
            dl != null ? 'Saved to $dl' : 'Could not write $chosen';
      }
    } else {
      final dl = await SessionExportHelper.saveTextToDownloads(
        filename: chosen,
        content: code,
        mimeType: 'text/plain',
      );
      savedNotice =
          dl != null ? 'Saved to $dl' : 'Save unavailable on this device';
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(savedNotice)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = AgySemanticColors.of(context);
    final isDiff = language.toLowerCase() == 'diff';
    final displayLang = language.isEmpty ? 'text' : language.split(_whitespaceSplitRegex).first;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: semantic.codeWellBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.codeWellBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: semantic.codeWellHeader,
            child: Row(
              children: [
                Text(
                  displayLang,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: semantic.textSecondary,
                  ),
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _saveToFile(context),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.save_alt_outlined,
                          size: 13,
                          color: semantic.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Save',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: semantic.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.copy_rounded,
                          size: 13,
                          color: semantic.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Copy',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: semantic.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: isDiff
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: code.split('\n').map((line) {
                      Color fg = semantic.codeWellFg;
                      Color? bg;
                      if (line.startsWith('+') && !line.startsWith('+++')) {
                        fg = semantic.diffAddFg;
                        bg = semantic.diffAddBg;
                      } else if (line.startsWith('-') && !line.startsWith('---')) {
                        fg = semantic.diffDelFg;
                        bg = semantic.diffDelBg;
                      } else if (line.startsWith('@@')) {
                        fg = semantic.diffHunkFg;
                      }
                      return Container(
                        color: bg,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            height: 1.45,
                            color: fg,
                          ),
                        ),
                      );
                    }).toList(),
                  )
                : Text(
                    code.trimRight(),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.45,
                      color: semantic.codeWellFg,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
