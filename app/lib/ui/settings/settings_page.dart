import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/auth_state.dart';
import '../../state/permissions_state.dart';
import '../../state/phone_state.dart';
import '../../state/settings_state.dart';
import '../../theme/app_theme.dart';
import '../../update/update_service.dart';
import '../auth/google_login_sheet.dart';
import '../phone/phone_control_page.dart';
import '../remote/ssh_hosts_page.dart';
import '../usage/usage_page.dart';
import 'runtime_setup_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _checkingUpdate = false;
  AppReleaseInfo? _latest;

  Future<void> _checkUpdates() async {
    setState(() => _checkingUpdate = true);
    try {
      final info = await UpdateService.instance.fetchLatestRelease();
      if (mounted) {
        setState(() => _latest = info);
        if (info == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No published GitHub releases yet')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final auth = ref.watch(authProvider);
    final perms = ref.watch(permissionsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Scrollbar(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
                ],
              ),
            ),
            const SizedBox(height: 12),
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
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
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
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: const Text('Check for Updates'),
                    subtitle: Text(
                      _latest != null
                          ? 'Latest release: ${_latest!.tagName}'
                          : 'dwicao/antigravity-go on GitHub Releases',
                    ),
                    trailing: _checkingUpdate
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    onTap: _checkingUpdate ? null : _checkUpdates,
                  ),
                  if (_latest?.arm64ApkUrl != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () => UpdateService.instance
                                  .downloadAndInstall(_latest!.arm64ApkUrl!),
                              child: Text('Install ${_latest!.tagName}'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () =>
                                launchUrl(Uri.parse(_latest!.htmlUrl)),
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
}
