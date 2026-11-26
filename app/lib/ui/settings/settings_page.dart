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
import '../backup/chat_backup_page.dart';
import '../cli/cli_manager_page.dart';
import '../phone/phone_control_page.dart';
import '../remote/custom_providers_page.dart';
import '../remote/ssh_hosts_page.dart';
import '../update/update_sheet.dart';
import '../usage/stats_page.dart';
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

  static const _compactBtnStyle = ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    minimumSize: WidgetStatePropertyAll(Size(0, 30)),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),
    textStyle: WidgetStatePropertyAll(
      TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  static const _compactSegStyle = ButtonStyle(
    visualDensity: VisualDensity(horizontal: -2, vertical: -2),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),
    textStyle: WidgetStatePropertyAll(
      TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

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

  Widget _section(String keywords, Widget child) {
    if (!_matches(keywords)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Card(margin: EdgeInsets.zero, child: child),
        ),
      ),
    );
  }

  Widget _tile(
    ThemeData theme, {
    required IconData icon,
    Color? iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      minLeadingWidth: 20,
      horizontalTitleGap: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Icon(icon, size: 19, color: iconColor),
      title: Text(
        title,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
            ),
      trailing: trailing ?? const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
    );
  }

  Widget _switch(
    ThemeData theme, {
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      dense: true,
      visualDensity: const VisualDensity(horizontal: -2, vertical: -3),
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
            ),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _badge(ThemeData theme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withOpacity(0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
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
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 20),
          children: [
            if (!_searchOpen)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: InkWell(
                      key: const ValueKey('settings-search-trigger'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => setState(() => _searchOpen = true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withOpacity(0.55),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search,
                              size: 17,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Search settings, performance, wallpaper…',
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 12.5,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            _section(
              'google account sign in gemini enterprise plan tier export import credentials backup transfer',
              _tile(
                theme,
                icon: auth.isAuthenticated
                    ? Icons.verified_user
                    : Icons.account_circle_outlined,
                iconColor: auth.isAuthenticated ? Colors.green : null,
                title: auth.isAuthenticated
                    ? (auth.email ?? auth.displayName ?? 'Signed in')
                    : 'Sign in with Google Account',
                subtitle: auth.isAuthenticated
                    ? '${auth.method.label} · ${auth.planTier.label} · Export / Import'
                    : 'Connect Google / Enterprise, or Import credentials backup',
                onTap: () => GoogleLoginSheet.show(context),
              ),
            ),
            _section(
              'stats spend cost tokens requests analytics backup chats restore export import sessions history json markdown usage quota runtime ssh remote hosts external models phone control safetygate',
              Column(
                children: [
                  _tile(
                    theme,
                    icon: Icons.bar_chart_rounded,
                    title: 'Stats & Spend',
                    subtitle:
                        'Total spend (\$), tokens, cache savings & per-model stats',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const StatsPage()),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.backup_outlined,
                    title: 'Chat Backup & Restore',
                    subtitle:
                        'Backup all chats (.json.gz), Markdown & restore from file',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ChatBackupPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.speed_rounded,
                    title: 'Usage Limits & Quotas',
                    subtitle:
                        '5h, Weekly, Gemini Argon/Neon/Carbon/Hydrogen, Claude & GPT',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const UsagePage()),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.memory,
                    title: 'On-Device Runtime',
                    subtitle: 'Install, logs, safe mode, reset',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const RuntimeSetupPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.dns_outlined,
                    title: 'SSH Remote Hosts',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SshHostsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.hub_outlined,
                    title: 'External /v1 Models',
                    subtitle: 'OpenAI-compatible APIs, Ollama, OpenRouter',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CustomProvidersPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.touch_app_outlined,
                    title: 'Phone Control & SafetyGate',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PhoneControlPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _section(
              'android permissions dex all files storage notifications microphone accessibility battery',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Android Permissions & Samsung DeX',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (perms.isDexMode) _badge(theme, 'DeX Active'),
                      ],
                    ),
                  ),
                  _tile(
                    theme,
                    icon: perms.allFilesAccess
                        ? Icons.folder_open
                        : Icons.folder_off_outlined,
                    iconColor:
                        perms.allFilesAccess ? Colors.green : Colors.amber,
                    title: 'All Files Access',
                    subtitle: perms.allFilesAccess
                        ? 'Granted (${perms.externalStorageRoot})'
                        : 'Required for /storage/emulated/0 & Downloads',
                    trailing: FilledButton.tonal(
                      style: _compactBtnStyle,
                      onPressed: () => ref
                          .read(permissionsProvider.notifier)
                          .requestAllFilesAccess(),
                      child: Text(perms.allFilesAccess ? 'Manage' : 'Grant'),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: perms.notifications && perms.microphone
                        ? Icons.check_circle_outline
                        : Icons.mic_none,
                    iconColor: perms.notifications && perms.microphone
                        ? Colors.green
                        : null,
                    title: 'Notifications & Microphone',
                    subtitle:
                        'Notifications: ${perms.notifications ? "Allowed" : "Off"} · Mic: ${perms.microphone ? "Allowed" : "Off"}',
                    trailing: OutlinedButton(
                      style: _compactBtnStyle,
                      onPressed: () => ref
                          .read(permissionsProvider.notifier)
                          .requestRuntimePermissions(),
                      child: const Text('Request'),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: perms.accessibility
                        ? Icons.accessibility_new
                        : Icons.accessibility,
                    iconColor: perms.accessibility ? Colors.green : null,
                    title: 'Phone Control Accessibility',
                    subtitle: perms.accessibility ? 'Connected' : 'Not enabled',
                    trailing: OutlinedButton(
                      style: _compactBtnStyle,
                      onPressed: () => ref
                          .read(phoneProvider.notifier)
                          .openAccessibilitySettings(),
                      child: const Text('Settings'),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: perms.batteryOptimizationExempt
                        ? Icons.battery_charging_full
                        : Icons.battery_saver_outlined,
                    iconColor: perms.batteryOptimizationExempt
                        ? Colors.green
                        : Colors.amber,
                    title: 'Background Battery Exemption',
                    subtitle: perms.batteryOptimizationExempt
                        ? 'Unrestricted (keeps long turns alive)'
                        : 'Recommended so Android stays alive',
                    trailing: OutlinedButton(
                      style: _compactBtnStyle,
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
            _section(
              'appearance theme dark light accent workspace layout haptic wallpaper dynamic color language locale',
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Appearance',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        style: _compactSegStyle,
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('System', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('Light', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('Dark', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                        selected: {settings.themeMode},
                        onSelectionChanged: (s) => ref
                            .read(settingsProvider.notifier)
                            .setThemeMode(s.first),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: AgyAccentPreset.values
                          .map(
                            (preset) => ChoiceChip(
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -3,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              labelPadding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              label: Text(
                                preset.label,
                                style: const TextStyle(fontSize: 12),
                              ),
                              selected: settings.accent == preset,
                              avatar: CircleAvatar(
                                backgroundColor: preset.seed,
                                radius: 7,
                              ),
                              onSelected: (_) => ref
                                  .read(settingsProvider.notifier)
                                  .setAccent(preset),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    _sectionLabel(theme, 'Workspace Layout Mode'),
                    const SizedBox(height: 5),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<DesktopLayoutOverride>(
                        showSelectedIcon: false,
                        style: _compactSegStyle,
                        segments: DesktopLayoutOverride.values
                            .map(
                              (d) => ButtonSegment(
                                value: d,
                                label: Text(
                                  d.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        selected: {settings.desktopLayout},
                        onSelectionChanged: (s) => ref
                            .read(settingsProvider.notifier)
                            .setDesktopLayout(s.first),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _switch(
                      theme,
                      title: 'Haptic feedback on reply complete',
                      subtitle: 'Gently vibrates when the agent finishes a turn',
                      value: settings.hapticOnComplete,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setHapticOnComplete(v),
                    ),
                    _switch(
                      theme,
                      title: 'Follow wallpaper color (Android 12+)',
                      subtitle:
                          'Adapt accent colors dynamically from wallpaper',
                      value: settings.followWallpaperColor,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setFollowWallpaperColor(v),
                    ),
                    const SizedBox(height: 6),
                    _sectionLabel(theme, 'App Language'),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: const [
                        ('en', 'English'),
                        ('id', 'Bahasa Indonesia'),
                        ('zh', '中文'),
                        ('es', 'Español'),
                      ]
                          .map(
                            (item) => ChoiceChip(
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -3,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              labelPadding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              label: Text(
                                item.$2,
                                style: const TextStyle(fontSize: 12),
                              ),
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
            _section(
              'display performance refresh rate 120hz motion blur thermal hardware',
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Display & Performance',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _badge(
                          theme,
                          '${perf.snapshot.tier.toUpperCase()} · ${perf.snapshot.maxRefreshHz.round()}Hz',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<RefreshRateMode>(
                        showSelectedIcon: false,
                        style: _compactSegStyle,
                        segments: RefreshRateMode.values
                            .map(
                              (m) => ButtonSegment(
                                value: m,
                                label: Text(
                                  m.name.toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        selected: {perf.refreshRateMode},
                        onSelectionChanged: (s) => ref
                            .read(performanceProvider.notifier)
                            .setRefreshRateMode(s.first),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _switch(
                      theme,
                      title: 'Reduce Motion',
                      subtitle: 'Disable page transitions and heavy animations',
                      value: perf.reduceMotion,
                      onChanged: (v) => ref
                          .read(performanceProvider.notifier)
                          .setReduceMotion(v),
                    ),
                    _switch(
                      theme,
                      title: 'Reduce Blur Effects',
                      subtitle: 'Prefer solid surfaces over GPU blur',
                      value: perf.reduceBlur,
                      onChanged: (v) => ref
                          .read(performanceProvider.notifier)
                          .setReduceBlur(v),
                    ),
                  ],
                ),
              ),
            ),
            _section(
              'notifications alerts reply approval background',
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Notifications & Background Alerts',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _switch(
                      theme,
                      title: 'Notify when reply finishes',
                      value: settings.notifyOnTurnComplete,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setNotifyOnTurnComplete(v),
                    ),
                    _switch(
                      theme,
                      title: 'Notify when tool approval needed',
                      value: settings.notifyOnApproval,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setNotifyOnApproval(v),
                    ),
                    _switch(
                      theme,
                      title: 'Only notify while app is backgrounded',
                      value: settings.notifyBackgroundOnly,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setNotifyBackgroundOnly(v),
                    ),
                    _switch(
                      theme,
                      title: 'Battery & network-aware eco policy',
                      subtitle:
                          'Warn on low battery (<15%) or cellular before heavy tools',
                      value: settings.batteryNetworkPolicyEnabled,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setBatteryNetworkPolicyEnabled(v),
                    ),
                  ],
                ),
              ),
            ),
            _section(
              'agent permissions preset turbo standard non-workspace file layout software',
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Agent Permissions & Desktop Layout',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<AntigravityPermissionPreset>(
                      value: settings.permissionPreset,
                      isExpanded: true,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Global Permission Preset',
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      items: AntigravityPermissionPreset.values
                          .map(
                            (p) => DropdownMenuItem(
                              value: p,
                              child: Text(
                                '${p.label} — ${p.description}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5),
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
                    const SizedBox(height: 4),
                    _switch(
                      theme,
                      title: 'Allow Non-Workspace File Access',
                      subtitle:
                          'Lets agents access /storage/emulated/0 & external folders',
                      value: settings.allowNonWorkspaceAccess,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setAllowNonWorkspaceAccess(v),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<AntigravityLayoutMode>(
                        showSelectedIcon: false,
                        style: _compactSegStyle,
                        segments: AntigravityLayoutMode.values
                            .map(
                              (l) => ButtonSegment(
                                value: l,
                                label: Text(
                                  l.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        selected: {settings.layoutMode},
                        onSelectionChanged: (s) => ref
                            .read(settingsProvider.notifier)
                            .setLayoutMode(s.first),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _section(
              'battery keep-alive oem samsung xiaomi oppo vivo diagnostics report cli flags',
              Column(
                children: [
                  _tile(
                    theme,
                    icon: Icons.battery_saver_rounded,
                    title: 'Background Keep-Alive Guide',
                    subtitle:
                        'Battery optimization check & Samsung/Xiaomi/OPPO/vivo setup',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const BackgroundGuidePage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.bug_report_outlined,
                    title: 'Diagnostics Bundle',
                    subtitle:
                        'Inspect, copy, share or export redacted diagnostics (.md)',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DiagnosticsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.terminal,
                    title: 'Antigravity CLI & Flags',
                    subtitle: settings.activeAgent.isNotEmpty
                        ? 'Agent: ${settings.activeAgent} · Manage mcp, plugin, remote-control'
                        : 'Manage mcp, plugin, agent, remote-control, & CLI flags',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CliManagerPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _section(
              'updates check release notes changelog whats new version apk install',
              Column(
                children: [
                  _tile(
                    theme,
                    icon: Icons.new_releases_outlined,
                    title: "What's New",
                    subtitle:
                        'Highlights & changelog for v${update.currentVersion}',
                    onTap: () => _showWhatsNewDialog(
                      context,
                      currentVersion: update.currentVersion,
                      latestNotes: update.latest?.notes,
                      changelogUrl:
                          update.latest?.changelogUrl ?? update.latest?.htmlUrl,
                    ),
                  ),
                  const Divider(height: 1),
                  _tile(
                    theme,
                    icon: Icons.system_update_alt,
                    title: 'Check for Updates',
                    subtitle: update.isDownloading
                        ? '${formatUpdateBytes(update.receivedBytes)} / ${update.effectiveTotalBytes != null ? formatUpdateBytes(update.effectiveTotalBytes!) : "…"} · Data used: ${formatUpdateBytes(update.totalDataUsedBytes)}'
                        : update.latest != null
                            ? (update.hasNewerVersion
                                ? 'Update available: ${update.latest!.tagName} (installed v${update.currentVersion})'
                                : 'Up to date (v${update.currentVersion}) · Data: ${formatUpdateBytes(update.totalDataUsedBytes)}')
                            : 'Installed v${update.currentVersion} · dwicao/antigravity-go',
                    trailing: update.checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
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
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(value: update.progress),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${formatUpdateBytes(update.receivedBytes)} / ${update.effectiveTotalBytes != null ? formatUpdateBytes(update.effectiveTotalBytes!) : "…"}${update.progress != null ? " (${(update.progress! * 100).round()}%)" : ""}',
                                  style: theme.textTheme.labelSmall,
                                ),
                              ),
                              OutlinedButton(
                                style: _compactBtnStyle,
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
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: update.hasNewerVersion
                                ? FilledButton(
                                    style: _compactBtnStyle,
                                    onPressed: () => UpdateSheet.show(context),
                                    child: Text(
                                      'Install ${update.latest!.tagName}',
                                    ),
                                  )
                                : OutlinedButton(
                                    style: _compactBtnStyle,
                                    onPressed: () => UpdateSheet.show(context),
                                    child: Text(
                                      'Up to date (${update.latest!.tagName})',
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            style: _compactBtnStyle,
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
