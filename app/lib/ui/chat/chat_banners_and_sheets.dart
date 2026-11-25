import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../../state/custom_providers_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../remote/custom_providers_page.dart';

class ChatOnboardingBanner extends StatelessWidget {
  const ChatOnboardingBanner({
    super.key,
    required this.isAuthenticated,
    required this.runtimeReady,
    required this.runtimeBusy,
    required this.isLocal,
    required this.onSignIn,
    required this.onInstallRuntime,
  });

  final bool isAuthenticated;
  final bool runtimeReady;
  final bool runtimeBusy;
  final bool isLocal;
  final VoidCallback onSignIn;
  final VoidCallback onInstallRuntime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCompact = MediaQuery.sizeOf(context).width < 460;
    final icon = Icon(
      !runtimeReady && isLocal ? Icons.terminal : Icons.account_circle,
      color: theme.colorScheme.primary,
    );
    final msg = Text(
      !runtimeReady && isLocal
          ? 'Install the on-device `agy` harness to run Antigravity agents on Android.'
          : 'Sign in with your Google Account to run Antigravity AI agents & view quotas.',
      style: theme.textTheme.bodySmall,
      maxLines: isCompact ? 3 : null,
      overflow: isCompact ? TextOverflow.ellipsis : null,
    );
    final action = (!runtimeReady && isLocal)
        ? FilledButton.tonal(
            onPressed: runtimeBusy ? null : onInstallRuntime,
            child: Text(runtimeBusy ? 'Installing…' : 'Install agy'),
          )
        : (!isAuthenticated)
            ? FilledButton.tonal(
                onPressed: onSignIn,
                child: const Text('Google Sign-In'),
              )
            : null;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: EdgeInsets.all(isCompact ? 10 : 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: isCompact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    icon,
                    const SizedBox(width: 10),
                    Expanded(child: msg),
                  ],
                ),
                if (action != null) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: action,
                  ),
                ],
              ],
            )
          : Row(
              children: [
                icon,
                const SizedBox(width: 10),
                Expanded(child: msg),
                ?action,
              ],
            ),
    );
  }
}

class ChatEmptyHero extends StatelessWidget {
  const ChatEmptyHero({super.key, required this.onPickSuggestion});

  final ValueChanged<String> onPickSuggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const suggestions = [
      '/plan Audit this project and propose improvements',
      '/goal Write unit tests and verify everything passes',
      'Check git status and summarize recent changes',
      '/boost Analyze performance bottlenecks in the codebase',
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.24),
                ),
              ),
              child: Icon(
                Icons.auto_awesome,
                size: 28,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Antigravity in your pocket',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                'Run AI agents on your phone or control your computer over SSH — with your Google Account & live 5h/weekly quota tracking.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: suggestions
                  .map(
                    (s) => ActionChip(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: BorderSide(
                        color: theme.colorScheme.outlineVariant.withOpacity(0.5),
                      ),
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHigh.withOpacity(0.6),
                      label: Text(
                        s,
                        style: theme.textTheme.labelMedium,
                      ),
                      onPressed: () => onPickSuggestion(s),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showChatModelPickerSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final currentId = ref.read(settingsProvider).selectedModelId;
  final customState = ref.read(customProvidersProvider);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        children: [
          Text(
            'Select Active Model',
            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          for (final m in AgyModelCatalog.builtIn)
            ListTile(
              dense: true,
              leading: Icon(
                customState.activeProviderId == null && m.id == currentId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(m.displayName),
              subtitle: Text(m.id),
              onTap: () async {
                Navigator.of(ctx).pop();
                await ref
                    .read(customProvidersProvider.notifier)
                    .selectProvider(null);
                await ref.read(settingsProvider.notifier).setModel(m.id);
                await ref.read(chatProvider.notifier).appendSystemFeedback(
                      'Switched active model to **${m.displayName}**.',
                    );
              },
            ),
          if (customState.profiles.isNotEmpty) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'External /v1 Models',
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            for (final p in customState.profiles)
              ListTile(
                dense: true,
                leading: Icon(
                  customState.activeProviderId == p.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text('${p.name} (${p.modelId})'),
                subtitle: Text(p.normalizedBaseUrl),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await ref
                      .read(customProvidersProvider.notifier)
                      .selectProvider(p.id);
                  await ref.read(chatProvider.notifier).appendSystemFeedback(
                        'Switched to external `/v1` model **${p.name} (${p.modelId})**.',
                      );
                },
              ),
          ],
          const Divider(),
          ListTile(
            dense: true,
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Configure External /v1 Models…'),
            onTap: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CustomProvidersPage(),
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> showChatSessionPickerSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final sessions = ref.read(sessionsProvider).sessions;
  final activeId = ref.read(sessionsProvider).activeSessionId;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        children: [
          Text(
            'Resume Session',
            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          for (final s in sessions)
            ListTile(
              dense: true,
              selected: s.id == activeId,
              leading: const Icon(Icons.chat_bubble_outline, size: 18),
              title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                s.lastPreview ?? s.workspacePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                ref.read(sessionsProvider.notifier).selectSession(s.id);
              },
            ),
        ],
      ),
    ),
  );
}
