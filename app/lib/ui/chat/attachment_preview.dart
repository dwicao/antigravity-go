import 'dart:io';

import 'package:flutter/material.dart';

import '../../state/chat_turn_helpers.dart';

/// Opens an interactive full-screen preview dialog for a local image attachment.
Future<void> showAttachmentImagePreviewDialog(
  BuildContext context,
  String path,
) {
  final filename = path.split('/').last.split('\\').last;
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                        size: 48,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        filename,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
              tooltip: 'Close preview',
              onPressed: () => Navigator.of(ctx).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Renders a rounded local image thumbnail with fallback and optional remove button.
class AttachmentImageThumbnail extends StatelessWidget {
  const AttachmentImageThumbnail({
    super.key,
    required this.path,
    this.width = 68,
    this.height = 68,
    this.borderRadius = 12,
    this.onRemove,
  });

  final String path;
  final double width;
  final double height;
  final double borderRadius;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filename = path.split('/').last.split('\\').last;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTap: () => showAttachmentImagePreviewDialog(context, path),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.5),
                ),
              ),
              child: Image.file(
                File(path),
                width: width,
                height: height,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.image_outlined,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (onRemove != null)
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black.withOpacity(0.68),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(
                    Icons.close_rounded,
                    size: 13,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Horizontal composer attachment strip showing mini image previews above the text input.
class AttachmentPreviewStrip extends StatelessWidget {
  const AttachmentPreviewStrip({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  final List<String> attachments;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    final hasImage = attachments.any(ChatTurnHelpers.isImagePath);

    return SizedBox(
      height: hasImage ? 76 : 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        children: attachments.map((a) {
          if (ChatTurnHelpers.isImagePath(a)) {
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AttachmentImageThumbnail(
                path: a,
                width: 68,
                height: 68,
                onRemove: () => onRemove(a),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: InputChip(
                label: Text(a.split('/').last.split('\\').last),
                onDeleted: () => onRemove(a),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
