import 'dart:io';

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
                      'Export an AES-256 encrypted backup to sign in instantly on another Android device without repeating Google OAuth.',
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
                              onPressed: _submitting ? null : _handleExport,
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

  Future<String?> _promptPassphrase({required bool isExport}) async {
    final passCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    var obscure = true;
    String? errorText;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            isExport ? 'Protect Credentials Backup' : 'Decrypt Credentials',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isExport
                    ? 'Enter a passphrase (min 4 characters) to encrypt your OAuth tokens with AES-256-GCM.'
                    : 'Enter the passphrase used when exporting this credentials backup.',
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

  Future<void> _handleExport() async {
    final passphrase = await _promptPassphrase(isExport: true);
    if (passphrase == null || !mounted) return;
    setState(() => _submitting = true);
    try {
      final bundle = await ref
          .read(authProvider.notifier)
          .exportCredentialsBundle(passphrase);
      if (!mounted) return;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .split('.')
          .first;
      final filename = 'antigravity-creds-$stamp.agycreds.json';
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
    String? bundleJson;
    final sourceChoice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Credentials'),
        content: const Text(
          'Select your exported `.agycreds.json` file or paste the encrypted bundle text.',
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
            label: const Text('Pick File'),
          ),
        ],
      ),
    );
    if (sourceChoice == null || !mounted) return;

    if (sourceChoice == 'file') {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty || !mounted) return;
      final path = files.first.path;
      if (path != null && path.isNotEmpty) {
        bundleJson = await File(path).readAsString();
      }
    } else {
      final ctrl = TextEditingController();
      bundleJson = await showDialog<String>(
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
    }

    if (bundleJson == null || bundleJson.trim().isEmpty || !mounted) return;
    final passphrase = await _promptPassphrase(isExport: false);
    if (passphrase == null || !mounted) return;

    setState(() => _submitting = true);
    try {
      final imported = await ref
          .read(authProvider.notifier)
          .importCredentialsBundle(
            bundleJson: bundleJson.trim(),
            passphrase: passphrase,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${imported.restoredFiles} file(s)${imported.email != null ? " · ${imported.email}" : ""}',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        final msg = e is PlatformException ? (e.message ?? e.code) : '$e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $msg')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
