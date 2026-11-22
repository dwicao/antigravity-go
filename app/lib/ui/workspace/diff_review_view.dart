import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/chat_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';

class DiffReviewView extends ConsumerStatefulWidget {
  const DiffReviewView({super.key});

  @override
  ConsumerState<DiffReviewView> createState() => _DiffReviewViewState();
}

class _DiffReviewViewState extends ConsumerState<DiffReviewView> {
  String _status = '';
  String _diff = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
      final fallback = ref.read(runtimeProvider).status.workspaceRoot ?? '';
      final cwd = projDir.isNotEmpty ? projDir : fallback;
      final (st, df) = await RuntimeBridge.instance.gitDiff(cwd);
      if (mounted) {
        setState(() {
          _status = st.trim();
          _diff = df.trim();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Text(
                'Review Changes',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Ask agent to review diff',
                onPressed: _diff.isEmpty
                    ? null
                    : () => ref.read(chatProvider.notifier).sendPrompt(
                          'Review the current git uncommitted changes and suggest any fixes.',
                        ),
                icon: const Icon(Icons.rate_review_outlined, size: 18),
              ),
              IconButton(
                tooltip: 'Refresh git diff',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : (_status.isEmpty && _diff.isEmpty)
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          'No uncommitted Git changes in the active project.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : Scrollbar(
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          if (_status.isNotEmpty) ...[
                            Text(
                              'Changed Files',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: SelectableText(
                                _status,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_diff.isNotEmpty) ...[
                            Text(
                              'Diff',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: SelectableText(
                                _diff,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
        ),
      ],
    );
  }
}
