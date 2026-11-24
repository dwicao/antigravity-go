import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/auth_state.dart';
import '../../state/performance_state.dart';
import '../../state/permissions_state.dart';
import '../../state/phone_state.dart';
import '../../state/settings_state.dart';
import '../../state/update_state.dart';
import '../../theme/app_theme.dart';
import '../auth/google_login_sheet.dart';
import '../cli/cli_manager_page.dart';
import '../phone/phone_control_page.dart';
import '../remote/custom_providers_page.dart';
import '../remote/ssh_hosts_page.dart';
import '../update/update_sheet.dart';
import '../usage/usage_page.dart';
import 'background_guide_page.dart';
import 'diagnostics_page.dart';
import 'runtime_setup_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _scrollController = ScrollController();
  String _searchQuery = '';
  bool _searchOpen = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _updateSearch(String value) {
    setState(() => _searchQuery = value);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  bool _matches(String keywords) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    return keywords.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final perf = ref.watch(performanceProvider);
    final auth = ref.watch(authProvider);
    final perms = ref.watch(permissionsProvider);
    final update = ref.watch(appUpdateProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: _searchOpen
            ? TextField(
                autofocus: true,
                onChanged: _updateSearch,
                decoration: const InputDecoration(
                  hintText: 'Search settings, performance, wallpaper…',
                  border: InputBorder.none,
                  filled: false,
                ),
              )
            : const Text('Settings'),
        actions: [
          IconButton(
            tooltip: _searchOpen ? 'Close search' : 'Search settings',
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _searchOpen = !_searchOpen;
                if (!_searchOpen) _searchQuery = '';
              });
              if (!_searchOpen && _scrollController.hasClients) {
                _scrollController.jumpTo(0);
              }
            },
          ),
        ],
      ),
      body: Scrollbar(
        controller: _scrollController,
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          children: [
            if (!_searchOpen)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: InkWell(
                  key: const ValueKey('settings-search-trigger'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => setState(() => _searchOpen = true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withOpacity(0.55),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.search,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Search settings, performance, wallpaper…',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_matches('google account sign in gemini enterprise plan tier'))
            Card(
              child: ListTile(
                leading: Icon(
                  auth.isAuthenticated
                      ? Icons.verified_user
                      : Icons.account_circle_outlined,
                  color: auth.isAuthenticated ? Colors.green : null,
                ),
                title: Text(
                  auth.isAuthenticated
                      ? (auth.email ?? auth.displayName ?? 'Signed in')
                      : 'Sign in with Google Account',
                ),
                subtitle: Text(
                  auth.isAuthenticated
                      ? '${auth.method.label} · ${auth.planTier.label}'
                      : 'Connect your personal Google or Gemini Enterprise account',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => GoogleLoginSheet.show(context),
              ),
            ),
            const SizedBox(height: 10),
            if (_matches('usage quota runtime ssh remote hosts external models phone control safetygate'))
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.speed_rounded),
                    title: const Text('Usage Limits & Quotas'),
                    subtitle: const Text(
                      '5h, Weekly, Gemini Argon/Neon/Carbon/Hydrogen, Claude & GPT',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const UsagePage()),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.memory),
                    title: const Text('On-Device Runtime'),
                    subtitle: const Text('Install, logs, safe mode, reset'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const RuntimeSetupPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: const Text('SSH Remote Hosts'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SshHostsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.hub_outlined),
                    title: const Text('External /v1 Models'),
                    subtitle: const Text('OpenAI-compatible APIs, Ollama, OpenRouter'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CustomProvidersPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.touch_app_outlined),
                    title: const Text('Phone Control & SafetyGate'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PhoneControlPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_matches('android permissions dex all files storage notifications microphone accessibility battery'))
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Row(
                      children: [
                        Text(
                          'Android Permissions & Samsung DeX',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        if (perms.isDexMode)
                          const Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('DeX Active'),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: Icon(
                      perms.allFilesAccess
                          ? Icons.folder_open
                          : Icons.folder_off_outlined,
                      color: perms.allFilesAccess ? Colors.green : Colors.amber,
                    ),
                    title: const Text('All Files Access'),
                    subtitle: Text(
                      perms.allFilesAccess
                          ? 'Granted (${perms.externalStorageRoot})'
                          : 'Required to access /storage/emulated/0 & Downloads',
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: () => ref
                          .read(permissionsProvider.notifier)
                          .requestAllFilesAccess(),
                      child: Text(perms.allFilesAccess ? 'Manage' : 'Grant'),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      perms.notifications && perms.microphone
                          ? Icons.check_circle_outline
                          : Icons.mic_none,
                      color: perms.notifications && perms.microphone
                          ? Colors.green
                          : null,
                    ),
                    title: const Text('Notifications & Microphone'),
                    subtitle: Text(
                      'Notifications: ${perms.notifications ? "Allowed" : "Off"} · Mic: ${perms.microphone ? "Allowed" : "Off"}',
                    ),
                    trailing: OutlinedButton(
                      onPressed: () => ref
                          .read(permissionsProvider.notifier)
                          .requestRuntimePermissions(),
                      child: const Text('Request'),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      perms.accessibility
                          ? Icons.accessibility_new
                          : Icons.accessibility,
                      color: perms.accessibility ? Colors.green : null,
                    ),
                    title: const Text('Phone Control Accessibility'),
                    subtitle: Text(
                      perms.accessibility ? 'Connected' : 'Not enabled',
                    ),
                    trailing: OutlinedButton(
                      onPressed: () => ref
                          .read(phoneProvider.notifier)
                          .openAccessibilitySettings(),
                      child: const Text('Settings'),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      perms.batteryOptimizationExempt
                          ? Icons.battery_charging_full
                          : Icons.battery_saver_outlined,
                      color: perms.batteryOptimizationExempt
                          ? Colors.green
                          : Colors.amber,
                    ),
                    title: const Text('Background Battery Exemption'),
                    subtitle: Text(
                      perms.batteryOptimizationExempt
                          ? 'Unrestricted (keeps long agent turns alive)'
                          : 'Recommended so Android does not suspend active turns',
                    ),
                    trailing: OutlinedButton(
                      onPressed: () => ref
                          .read(permissionsProvider.notifier)
                          .requestBatteryOptimizationExemption(),
                      child: Text(
                        perms.batteryOptimizationExempt ? 'Manage' : 'Allow',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_matches('appearance theme dark light accent workspace layout haptic wallpaper dynamic color language locale'))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Appearance',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('System'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('Light'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('Dark'),
                        ),
                      ],
                      selected: {settings.themeMode},
                      onSelectionChanged: (s) => ref
                          .read(settingsProvider.notifier)
                          .setThemeMode(s.first),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: AgyAccentPreset.values
                          .map(
                            (preset) => ChoiceChip(
                              label: Text(preset.label),
                              selected: settings.accent == preset,
                              avatar: CircleAvatar(
                                backgroundColor: preset.seed,
                                radius: 8,
                              ),
                              onSelected: (_) => ref
                                  .read(settingsProvider.notifier)
                                  .setAccent(preset),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Workspace Layout Mode',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SegmentedButton<DesktopLayoutOverride>(
                      segments: DesktopLayoutOverride.values
                          .map(
                            (d) => ButtonSegment(
                              value: d,
                              label: Text(d.label),
                            ),
                          )
                          .toList(),
                      selected: {settings.desktopLayout},
                      onSelectionChanged: (s) => ref
                          .read(settingsProvider.notifier)
                          .setDesktopLayout(s.first),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Haptic feedback on reply complete'),
                      subtitle: const Text(
                        'Gently vibrates when the agent finishes a turn',
                      ),
                      value: settings.hapticOnComplete,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setHapticOnComplete(v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Follow wallpaper color (Android 12+)'),
                      subtitle: const Text(
                        'Adapt accent colors dynamically from your home wallpaper',
                      ),
                      value: settings.followWallpaperColor,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setFollowWallpaperColor(v),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'App Language',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: const [
                        ('en', 'English'),
                        ('id', 'Bahasa Indonesia'),
                        ('zh', '中文'),
                        ('es', 'Español'),
                      ]
                          .map(
                            (item) => ChoiceChip(
                              label: Text(item.$2),
                              selected: settings.localeCode == item.$1,
                              onSelected: (_) => ref
                                  .read(settingsProvider.notifier)
                                  .setLocaleCode(item.$1),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_matches('display performance refresh rate 120hz motion blur thermal hardware'))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Display & Performance',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            '${perf.snapshot.tier.toUpperCase()} · ${perf.snapshot.maxRefreshHz.round()}Hz',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<RefreshRateMode>(
                      segments: RefreshRateMode.values
                          .map(
                            (m) => ButtonSegment(
                              value: m,
                              label: Text(m.name.toUpperCase()),
                            ),
                          )
                          .toList(),
                      selected: {perf.refreshRateMode},
                      onSelectionChanged: (s) => ref
                          .read(performanceProvider.notifier)
                          .setRefreshRateMode(s.first),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Reduce Motion'),
                      subtitle: const Text(
                        'Disable page transitions and heavy animations',
                      ),
                      value: perf.reduceMotion,
                      onChanged: (v) => ref
                          .read(performanceProvider.notifier)
                          .setReduceMotion(v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Reduce Blur Effects'),
                      subtitle: const Text(
                        'Prefer solid translucent surfaces over GPU glass blur',
                      ),
                      value: perf.reduceBlur,
                      onChanged: (v) => ref
                          .read(performanceProvider.notifier)
                          .setReduceBlur(v),
                    ),
                  ],
                ),
              ),
            ),
            if (_matches('notifications alerts reply approval background'))
            const SizedBox(height: 12),
            if (_matches('notifications alerts reply approval background'))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Notifications & Background Alerts',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Notify when reply finishes'),
                      value: settings.notifyOnTurnComplete,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setNotifyOnTurnComplete(v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Notify when tool approval needed'),
                      value: settings.notifyOnApproval,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setNotifyOnApproval(v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Only notify while app is backgrounded'),
                      value: settings.notifyBackgroundOnly,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setNotifyBackgroundOnly(v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_matches('agent permissions preset turbo standard non-workspace file layout software'))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Agent Permissions & Desktop Layout',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<AntigravityPermissionPreset>(
                      value: settings.permissionPreset,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Global Permission Preset',
                      ),
                      items: AntigravityPermissionPreset.values
                          .map(
                            (p) => DropdownMenuItem(
                              value: p,
                              child: Text(
                                '${p.label} — ${p.description}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (p) {
                        if (p != null) {
                          ref
                              .read(settingsProvider.notifier)
                              .setPermissionPreset(p);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Allow Non-Workspace File Access'),
                      subtitle: const Text(
                        'Lets agents access /storage/emulated/0, /sdcard, and external folders',
                      ),
                      value: settings.allowNonWorkspaceAccess,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setAllowNonWorkspaceAccess(v),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<AntigravityLayoutMode>(
                      segments: AntigravityLayoutMode.values
                          .map(
                            (l) => ButtonSegment(
                              value: l,
                              label: Text(l.label),
                            ),
                          )
                          .toList(),
                      selected: {settings.layoutMode},
                      onSelectionChanged: (s) => ref
                          .read(settingsProvider.notifier)
                          .setLayoutMode(s.first),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_matches('battery keep-alive oem samsung xiaomi oppo vivo diagnostics report cli flags'))
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.battery_saver_rounded),
                    title: const Text('Background Keep-Alive Guide'),
                    subtitle: const Text(
                      'Battery optimization check & Samsung/Xiaomi/OPPO/vivo setup',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const BackgroundGuidePage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.bug_report_outlined),
                    title: const Text('Diagnostics Bundle'),
                    subtitle: const Text(
                      'Inspect, copy, share or export redacted diagnostics (.md)',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DiagnosticsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.terminal),
                    title: const Text('Antigravity CLI & Flags'),
                    subtitle: Text(
                      settings.activeAgent.isNotEmpty
                          ? 'Agent: ${settings.activeAgent} · Manage mcp, plugin, remote-control'
                          : 'Manage mcp, plugin, agent, remote-control, & CLI flags',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CliManagerPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_matches('updates check release notes changelog whats new version apk install'))
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.new_releases_outlined),
                    title: const Text("What's New"),
                    subtitle: Text(
                      'Highlights & changelog for v${update.currentVersion}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showWhatsNewDialog(
                      context,
                      currentVersion: update.currentVersion,
                      latestNotes: update.latest?.notes,
                      changelogUrl:
                          update.latest?.changelogUrl ?? update.latest?.htmlUrl,
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: const Text('Check for Updates'),
                    subtitle: Text(
                      update.isDownloading
                          ? '${formatUpdateBytes(update.receivedBytes)} / ${update.effectiveTotalBytes != null ? formatUpdateBytes(update.effectiveTotalBytes!) : "…"} · Data used: ${formatUpdateBytes(update.totalDataUsedBytes)}'
                          : update.latest != null
                              ? (update.hasNewerVersion
                                  ? 'Update available: ${update.latest!.tagName} (installed v${update.currentVersion}) · Data used: ${formatUpdateBytes(update.totalDataUsedBytes)}'
                                  : 'Up to date (v${update.currentVersion}) · Data used: ${formatUpdateBytes(update.totalDataUsedBytes)}')
                              : 'Installed v${update.currentVersion} · dwicao/antigravity-go',
                    ),
                    trailing: update.checking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    onTap: update.checking
                        ? null
                        : () async {
                            final info = await ref
                                .read(appUpdateProvider.notifier)
                                .checkForUpdates();
                            if (!context.mounted) return;
                            if (info != null) {
                              await UpdateSheet.show(context);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content:
                                      Text('No published GitHub releases yet'),
                                ),
                              );
                            }
                          },
                  ),
                  if (update.isDownloading)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(value: update.progress),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${formatUpdateBytes(update.receivedBytes)} / ${update.effectiveTotalBytes != null ? formatUpdateBytes(update.effectiveTotalBytes!) : "…"}${update.progress != null ? " (${(update.progress! * 100).round()}%)" : ""}',
                                  style: theme.textTheme.labelSmall,
                                ),
                              ),
                              OutlinedButton(
                                onPressed: () => ref
                                    .read(appUpdateProvider.notifier)
                                    .cancelUpdate(),
                                child: const Text('Cancel'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else if (update.latest?.arm64ApkUrl != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: update.hasNewerVersion
                                ? FilledButton(
                                    onPressed: () => UpdateSheet.show(context),
                                    child: Text('Install ${update.latest!.tagName}'),
                                  )
                                : OutlinedButton(
                                    onPressed: () => UpdateSheet.show(context),
                                    child: Text('Up to date (${update.latest!.tagName})'),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () =>
                                launchUrl(Uri.parse(update.latest!.htmlUrl)),
                            child: const Text('Release Notes'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showWhatsNewDialog(
    BuildContext context, {
    required String currentVersion,
    String? latestNotes,
    String? changelogUrl,
  }) async {
    var notes = latestNotes?.trim() ?? '';
    var versionLabel = currentVersion;
    var url = changelogUrl ??
        'https://github.com/dwicao/antigravity-go/blob/main/CHANGELOG.md';
    if (notes.isEmpty) {
      try {
        final raw = await rootBundle.loadString('assets/version.json');
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          versionLabel = decoded['version']?.toString() ?? versionLabel;
          notes = decoded['releaseNotes']?.toString().trim() ?? '';
          url = decoded['changelogUrl']?.toString() ?? url;
        }
      } catch (_) {
        // Fallback below if asset unavailable in unit tests.
      }
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("What's New in v$versionLabel"),
        content: SingleChildScrollView(
          child: SelectableText(
            notes.isEmpty
                ? 'See CHANGELOG.md for complete release history.'
                : notes,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => launchUrl(Uri.parse(url)),
            child: const Text('Full Changelog'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
