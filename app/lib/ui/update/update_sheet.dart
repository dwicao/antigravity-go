import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/update_state.dart';
import '../../theme/app_theme.dart';
import '../../update/update_service.dart';
import '../chat/render/agy_markdown.dart';

/// In-app APK update sheet modeled on `dsh-Go`'s `UpdateSheet`:
/// shows progress bar (`%`), `received / total` bytes, speed, total update
/// data used, and a Cancel button during active downloads.
class UpdateSheet extends ConsumerWidget {
  const UpdateSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const UpdateSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateProvider);
    final notifier = ref.read(appUpdateProvider.notifier);
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final release = update.latest;
    final total = update.effectiveTotalBytes;
    final pct = update.progress != null
        ? (update.progress! * 100).round().clamp(0, 100)
        : null;

    final phaseLabel = switch (update.phase) {
      UpdateTransferPhase.downloading => 'Downloading APK…',
      UpdateTransferPhase.verifying => 'Verifying SHA-256 checksum…',
      UpdateTransferPhase.installing => 'Launching Android installer…',
      UpdateTransferPhase.cancelled => 'Download cancelled',
      UpdateTransferPhase.failed => 'Update failed',
      UpdateTransferPhase.idle => release == null
          ? 'Installed v${update.currentVersion}'
          : update.hasNewerVersion
              ? 'Update available: ${release.tagName} (installed v${update.currentVersion})'
              : 'Already on latest version (v${update.currentVersion})',
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.system_update_alt,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    release != null
                        ? 'Antigravity Go ${release.tagName}'
                        : 'App Update',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (update.checking)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Check again',
                    onPressed: notifier.checkForUpdates,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              total != null
                  ? '$phaseLabel · ${formatUpdateBytes(total)}'
                  : phaseLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: semantic.textSecondary,
              ),
            ),
            const SizedBox(height: 12),

            // Progress Bar + Received vs Total + Total Data Used
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (update.isDownloading || update.receivedBytes > 0) ...[
                    LinearProgressIndicator(
                      value: update.phase == UpdateTransferPhase.verifying ||
                              update.phase == UpdateTransferPhase.installing
                          ? 1.0
                          : update.progress,
                      minHeight: 7,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            total != null
                                ? '${formatUpdateBytes(update.receivedBytes)} / ${formatUpdateBytes(total)}'
                                : '${formatUpdateBytes(update.receivedBytes)} downloaded',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (pct != null)
                          Text(
                            '$pct%',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                    if (update.speedBps > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Speed: ${formatUpdateBytes(update.speedBps)}/s',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: semantic.textTertiary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                  ],
                  Row(
                    children: [
                      Icon(
                        Icons.data_usage_outlined,
                        size: 14,
                        color: semantic.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Total data used for updates: ${formatUpdateBytes(update.totalDataUsedBytes)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: semantic.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (update.needsInstallPermission) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Allow "Install unknown apps" permission before installing APK.',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.tertiary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () async {
                            await UpdateService.instance
                                .openInstallUnknownAppsSettings();
                            await notifier.refreshInstallPermission();
                          },
                          child: const Text('Grant'),
                        ),
                      ],
                    ),
                  ],
                  if (update.errorMessage != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      update.errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            if (release?.notes != null && release!.notes!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Release Notes (${release.tagName})',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: semantic.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: AgyMarkdown(data: release.notes!.trim()),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),

            Row(
              children: [
                if (update.isDownloading)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: notifier.cancelUpdate,
                      icon: const Icon(Icons.close),
                      label: const Text('Cancel Update'),
                    ),
                  )
                else ...[
                  Expanded(
                    child: update.hasNewerVersion || release == null
                        ? FilledButton.icon(
                            onPressed: release?.arm64ApkUrl != null
                                ? notifier.startUpdate
                                : null,
                            icon: const Icon(Icons.download_rounded),
                            label: Text(
                              release != null
                                  ? (update.phase ==
                                              UpdateTransferPhase.cancelled ||
                                          update.phase ==
                                              UpdateTransferPhase.failed
                                      ? 'Retry ${release.tagName}'
                                      : 'Download & Install ${release.tagName}')
                                  : 'No APK available',
                            ),
                          )
                        : OutlinedButton.icon(
                            onPressed: release.arm64ApkUrl != null
                                ? notifier.startUpdate
                                : null,
                            icon: const Icon(Icons.check_circle_outline),
                            label: Text('Up to date · Reinstall ${release.tagName}'),
                          ),
                  ),
                  if (release != null) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => launchUrl(
                        Uri.parse(release.changelogUrl ?? release.htmlUrl),
                      ),
                      child: const Text('Changelog'),
                    ),
                  ],
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
