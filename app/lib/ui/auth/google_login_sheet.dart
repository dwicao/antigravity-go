import 'dart:convert';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/google_auth_service.dart';
import '../../state/auth_state.dart';
import '../../state/runtime_state.dart';
import '../../state/session_export_helper.dart';

class GoogleLoginSheet extends ConsumerStatefulWidget {
  const GoogleLoginSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const GoogleLoginSheet(),
    );
  }

  @override
  ConsumerState<GoogleLoginSheet> createState() => _GoogleLoginSheetState();
}

class _GoogleLoginSheetState extends ConsumerState<GoogleLoginSheet> {
  int _tab = 0; // 0: Google Account, 1: Enterprise GCP, 2: Gemini API Key
  final _codeController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _projectController = TextEditingController();
  String _gcpLocation = 'global';
  bool _submitting = false;

  @override
  void dispose() {
    _codeController.dispose();
    _apiKeyController.dispose();
    _projectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final runtime = ref.watch(runtimeProvider);
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.account_circle_outlined,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Antigravity Account',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        auth.isAuthenticated
                            ? '${auth.displayName ?? auth.email ?? "Signed in"} · ${auth.planTier.label}'
                            : 'Sign in with Google to use AI agents & track limits',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (auth.savedAccounts.isNotEmpty) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.people_alt_outlined,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Saved Accounts (${auth.savedAccounts.length})',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _submitting ? null : _handleImport,
                            icon: const Icon(Icons.person_add_alt_1, size: 16),
                            label: const Text('Add'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      for (final acct in auth.savedAccounts)
                        _SavedAccountTile(
                          account: acct,
                          busy: _submitting,
                          onSwitch: acct.isActive
                              ? null
                              : () => _handleSwitchAccount(acct),
                          onExport: () => _handleExport(
                            accountId: acct.id,
                            accountLabel: acct.displayName,
                          ),
                          onRemove: () => _handleRemoveAccount(acct),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (auth.isAuthenticated) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.verified_user, color: Colors.green),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              auth.email ?? auth.displayName ?? 'Authenticated',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Chip(label: Text(auth.planTier.label)),
                        ],
                      ),
                      if (auth.gcpProject != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'GCP Project: ${auth.gcpProject} (${auth.gcpLocation ?? "global"})',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: () =>
                                ref.read(authProvider.notifier).refresh(),
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Refresh'),
                          ),
                          const SizedBox(width: 10),
                          FilledButton.tonalIcon(
                            onPressed: () async {
                              await ref.read(authProvider.notifier).signOut();
                            },
                            icon: const Icon(Icons.logout, size: 18),
                            label: const Text('Sign Out'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Google')),
                ButtonSegment(value: 1, label: Text('Enterprise')),
                ButtonSegment(value: 2, label: Text('API Key')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
            const SizedBox(height: 16),
            if (_tab == 0) ...[
              if (!runtime.status.isReady)
                Card(
                  color: theme.colorScheme.secondaryContainer.withOpacity(0.45),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(Icons.download_for_offline_outlined),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Install the on-device Antigravity CLI (`agy`) first so Google OAuth tokens can be stored & used locally.',
                          ),
                        ),
                        TextButton(
                          onPressed: runtime.busy
                              ? null
                              : () => ref
                                  .read(runtimeProvider.notifier)
                                  .installAndStart(),
                          child: Text(runtime.busy ? 'Installing...' : 'Install'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _submitting || !runtime.status.isReady
                          ? null
                          : () async {
                              setState(() => _submitting = true);
                              try {
                                await ref
                                    .read(authProvider.notifier)
                                    .startGoogleSignIn();
                              } finally {
                                if (mounted) setState(() => _submitting = false);
                              }
                            },
                      icon: const Icon(Icons.login),
                      label: const Text('Sign in with Google Account'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _submitting || !runtime.status.isReady
                        ? null
                        : () async {
                            setState(() => _submitting = true);
                            final nav = Navigator.of(context);
                            try {
                              await ref
                                  .read(authProvider.notifier)
                                  .refresh(verifyWithCli: true);
                              if (mounted &&
                                  ref.read(authProvider).isAuthenticated) {
                                nav.pop();
                              }
                            } finally {
                              if (mounted) setState(() => _submitting = false);
                            }
                          },
                    icon: const Icon(Icons.verified_outlined, size: 18),
                    label: const Text('Verify'),
                  ),
                ],
              ),
              if (auth.pendingOAuthUrl != null) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Complete Google Sign-In in your browser, then paste the verification code below if prompted:',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => GoogleAuthService()
                                  .openOAuthUrl(auth.pendingOAuthUrl!),
                              icon: const Icon(Icons.open_in_browser, size: 18),
                              label: const Text('Open Google Auth'),
                            ),
                            TextButton.icon(
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: auth.pendingOAuthUrl!),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('OAuth URL copied'),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.copy, size: 18),
                              label: const Text('Copy URL'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (auth.awaitingCode) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _codeController,
                  decoration: const InputDecoration(
                    labelText: 'Authorization / Verification Code',
                    hintText: 'Paste code from Google OAuth page',
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () async {
                    if (_codeController.text.trim().isEmpty) return;
                    final nav = Navigator.of(context);
                    await ref
                        .read(authProvider.notifier)
                        .submitVerificationCode(_codeController.text);
                    if (mounted && ref.read(authProvider).isAuthenticated) {
                      nav.pop();
                    }
                  },
                  child: const Text('Complete Google Sign-In'),
                ),
              ],
              if (auth.errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  auth.errorMessage!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ] else if (_tab == 1) ...[
              TextField(
                controller: _projectController,
                decoration: const InputDecoration(
                  labelText: 'Google Cloud Project ID',
                  hintText: 'my-gcp-project',
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: _gcpLocation,
                decoration: const InputDecoration(labelText: 'Region'),
                items: const [
                  DropdownMenuItem(value: 'global', child: Text('global')),
                  DropdownMenuItem(value: 'us', child: Text('us')),
                  DropdownMenuItem(value: 'eu', child: Text('eu')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _gcpLocation = v);
                },
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: !runtime.status.isReady
                    ? null
                    : () async {
                        await ref
                            .read(authProvider.notifier)
                            .configureEnterpriseGcp(
                              projectId: _projectController.text,
                              location: _gcpLocation,
                            );
                        await ref
                            .read(authProvider.notifier)
                            .startGoogleSignIn(enterprise: true);
                      },
                icon: const Icon(Icons.business),
                label: const Text('Sign in with Gemini Enterprise'),
              ),
            ] else ...[
              TextField(
                controller: _apiKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'GEMINI_API_KEY',
                  hintText: 'AIza...',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  final nav = Navigator.of(context);
                  await ref
                      .read(authProvider.notifier)
                      .saveGeminiApiKey(_apiKeyController.text);
                  if (mounted) nav.pop();
                },
                icon: const Icon(Icons.key),
                label: const Text('Save API Key Securely'),
              ),
            ],
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.swap_horiz_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Transfer Credentials',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Export an AES-256 encrypted backup or import one or multiple `.agycreds.json` files to switch between accounts without repeating Google OAuth.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        if (auth.isAuthenticated) ...[
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _submitting
                                  ? null
                                  : () => _handleExport(),
                              icon: const Icon(
                                Icons.file_upload_outlined,
                                size: 18,
                              ),
                              label: const Text('Export'),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _submitting ? null : _handleImport,
                            icon: const Icon(
                              Icons.file_download_outlined,
                              size: 18,
                            ),
                            label: const Text('Import Credentials'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptPassphrase({
    required bool isExport,
    String? subjectLabel,
    String? initialError,
  }) async {
    final passCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    var obscure = true;
    String? errorText = initialError;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            isExport
                ? 'Protect Credentials Backup'
                : (subjectLabel != null
                    ? 'Decrypt $subjectLabel'
                    : 'Decrypt Credentials'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isExport
                    ? 'Enter a passphrase (min 4 characters) to encrypt ${subjectLabel ?? "your OAuth tokens"} with AES-256-GCM.'
                    : 'Enter the passphrase used when exporting ${subjectLabel ?? "this credentials backup"}.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  errorText: errorText,
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setDialogState(() => obscure = !obscure),
                  ),
                ),
              ),
              if (isExport) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: confirmCtrl,
                  obscureText: obscure,
                  decoration: const InputDecoration(
                    labelText: 'Confirm Passphrase',
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final p = passCtrl.text.trim();
                if (p.length < 4) {
                  setDialogState(
                    () => errorText = 'Minimum 4 characters required',
                  );
                  return;
                }
                if (isExport && p != confirmCtrl.text.trim()) {
                  setDialogState(
                    () => errorText = 'Passphrases do not match',
                  );
                  return;
                }
                Navigator.of(ctx).pop(p);
              },
              child: Text(isExport ? 'Encrypt & Export' : 'Unlock'),
            ),
          ],
        ),
      ),
    );
    passCtrl.dispose();
    confirmCtrl.dispose();
    return result;
  }

  Future<void> _handleSwitchAccount(SavedAccount account) async {
    setState(() => _submitting = true);
    try {
      await ref.read(authProvider.notifier).switchAccount(account.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Switched to ${account.displayName}')),
      );
    } catch (e) {
      if (mounted) {
        final msg = e is PlatformException ? (e.message ?? e.code) : '$e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Switch failed: $msg')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _handleRemoveAccount(SavedAccount account) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Saved Account'),
        content: Text(
          'Remove ${account.displayName} from saved accounts on this device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _submitting = true);
    try {
      await ref.read(authProvider.notifier).removeAccount(account.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed ${account.displayName}')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _handleExport({
    String? accountId,
    String? accountLabel,
  }) async {
    final passphrase = await _promptPassphrase(
      isExport: true,
      subjectLabel: accountLabel,
    );
    if (passphrase == null || !mounted) return;
    setState(() => _submitting = true);
    try {
      final bundle = await ref
          .read(authProvider.notifier)
          .exportCredentialsBundle(passphrase, accountId: accountId);
      if (!mounted) return;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .split('.')
          .first;
      final slug = (accountLabel ?? 'creds')
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-|-$'), '');
      final filename = 'antigravity-${slug.isEmpty ? "creds" : slug}-$stamp.agycreds.json';
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Encrypted Backup Ready'),
          content: const Text(
            'Save the encrypted `.agycreds.json` file to Downloads or share it directly to your other Android phone.',
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: bundle));
                Navigator.of(ctx).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Encrypted credentials copied'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await SessionExportHelper.shareText(
                  'Antigravity Go Credentials',
                  bundle,
                );
              },
              icon: const Icon(Icons.share_outlined, size: 16),
              label: const Text('Share'),
            ),
            FilledButton.icon(
              onPressed: () async {
                final saved = await SessionExportHelper.saveTextToDownloads(
                  filename: filename,
                  content: bundle,
                  mimeType: 'application/json',
                );
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        saved != null
                            ? 'Saved to $saved'
                            : 'Save unavailable on this device',
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.download_rounded, size: 16),
              label: const Text('Save File'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        final msg = e is PlatformException ? (e.message ?? e.code) : '$e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $msg')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _handleImport() async {
    final entries = <({String label, String json})>[];
    final sourceChoice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Credentials'),
        content: const Text(
          'Pick one or more `.agycreds.json` files to add multiple accounts, or paste an encrypted bundle.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.of(ctx).pop('paste'),
            icon: const Icon(Icons.paste_rounded, size: 16),
            label: const Text('Paste Text'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop('file'),
            icon: const Icon(Icons.folder_open_outlined, size: 16),
            label: const Text('Pick File(s)'),
          ),
        ],
      ),
    );
    if (sourceChoice == null || !mounted) return;

    if (sourceChoice == 'file') {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty || !mounted) return;
      for (final f in files) {
        String? raw;
        final path = f.path;
        if (path != null && path.isNotEmpty) {
          raw = await File(path).readAsString();
        } else {
          final bytes = await f.readAsBytes();
          if (bytes.isNotEmpty) {
            raw = utf8.decode(bytes);
          }
        }
        if (raw != null && raw.trim().isNotEmpty) {
          entries.add((label: f.name, json: raw.trim()));
        }
      }
    } else {
      final ctrl = TextEditingController();
      final pasted = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Paste Encrypted Bundle'),
          content: TextField(
            controller: ctrl,
            maxLines: 6,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '{"format":"antigravity-go-creds-v1", ...}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Next'),
            ),
          ],
        ),
      );
      ctrl.dispose();
      if (pasted != null && pasted.trim().isNotEmpty) {
        entries.add((label: 'pasted bundle', json: pasted.trim()));
      }
    }

    if (entries.isEmpty || !mounted) return;

    String? sharedPassphrase;
    final importedLabels = <String>[];
    String? firstError;

    setState(() => _submitting = true);
    try {
      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        final isLast = i == entries.length - 1;
        var passphrase = sharedPassphrase;
        String? retryError;
        var done = false;

        while (!done && mounted) {
          if (passphrase == null) {
            passphrase = await _promptPassphrase(
              isExport: false,
              subjectLabel: entries.length > 1 ? entry.label : null,
              initialError: retryError,
            );
            if (passphrase == null) break;
          }
          try {
            final res = await ref
                .read(authProvider.notifier)
                .importCredentialsBundle(
                  bundleJson: entry.json,
                  passphrase: passphrase,
                  activate: isLast,
                );
            sharedPassphrase = passphrase;
            importedLabels.add(res.email ?? entry.label);
            done = true;
          } catch (e) {
            final msg = e is PlatformException ? (e.message ?? e.code) : '$e';
            if (msg.toLowerCase().contains('passphrase')) {
              retryError = 'Wrong passphrase for ${entry.label}';
              passphrase = null;
              sharedPassphrase = null;
            } else {
              firstError ??= '${entry.label}: $msg';
              done = true;
            }
          }
        }
      }

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (importedLabels.isNotEmpty) {
        final summary = importedLabels.length == 1
            ? 'Imported account: ${importedLabels.first}'
            : 'Imported ${importedLabels.length} accounts (${importedLabels.join(', ')})';
        messenger.showSnackBar(SnackBar(content: Text(summary)));
      } else if (firstError != null) {
        messenger.showSnackBar(
          SnackBar(content: Text('Import failed: $firstError')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _SavedAccountTile extends StatelessWidget {
  const _SavedAccountTile({
    required this.account,
    required this.busy,
    required this.onSwitch,
    required this.onExport,
    required this.onRemove,
  });

  final SavedAccount account;
  final bool busy;
  final VoidCallback? onSwitch;
  final VoidCallback onExport;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: busy ? null : onSwitch,
      leading: Icon(
        account.isActive ? Icons.verified_user : Icons.account_circle_outlined,
        size: 22,
        color: account.isActive ? Colors.green : theme.colorScheme.primary,
      ),
      title: Text(
        account.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: account.isActive ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        account.gcpProject != null
            ? '${account.method.label} · ${account.gcpProject}'
            : '${account.method.label} · ${account.planTier.label}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (account.isActive)
            const Chip(
              visualDensity: VisualDensity.compact,
              label: Text('Active', style: TextStyle(fontSize: 11)),
            )
          else
            TextButton(
              onPressed: busy ? null : onSwitch,
              child: const Text('Switch'),
            ),
          PopupMenuButton<String>(
            enabled: !busy,
            iconSize: 18,
            onSelected: (v) {
              if (v == 'export') onExport();
              if (v == 'remove') onRemove();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Export')),
              PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}
