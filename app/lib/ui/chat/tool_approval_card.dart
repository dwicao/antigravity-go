import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'secret_mask.dart';

class ToolApprovalCard extends StatelessWidget {
  const ToolApprovalCard({
    super.key,
    required this.request,
    required this.onSelectOption,
  });

  final AgyPermissionRequestEvent request;
  final ValueChanged<String> onSelectOption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.secondaryContainer.withOpacity(0.55),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    request.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: semantic.textPrimary,
                    ),
                  ),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(request.toolName),
                ),
              ],
            ),
            if (request.commandOrPath != null &&
                request.commandOrPath!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: semantic.codeWellBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: semantic.codeWellBorder),
                ),
                child: SelectableText(
                  AgySecretMask.mask(request.commandOrPath!),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: semantic.codeWellFg,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: request.options.isEmpty
                  ? [
                      FilledButton(
                        onPressed: () => onSelectOption('allow_once'),
                        child: const Text('Allow'),
                      ),
                      OutlinedButton(
                        onPressed: () => onSelectOption('reject_once'),
                        child: const Text('Deny'),
                      ),
                    ]
                  : request.options
                      .map(
                        (opt) => opt.kind.contains('reject')
                            ? OutlinedButton(
                                onPressed: () => onSelectOption(opt.optionId),
                                child: Text(opt.name),
                              )
                            : FilledButton(
                                onPressed: () => onSelectOption(opt.optionId),
                                child: Text(opt.name),
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
