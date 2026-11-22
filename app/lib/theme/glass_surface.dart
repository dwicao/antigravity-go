import 'dart:ui';

import 'package:flutter/material.dart';

/// Frosted glass container matching DSH Go's glassmorphic design language.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.padding,
    this.blur = 14,
    this.color,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fill = color ??
        (isDark
            ? const Color(0xCC161C2E)
            : const Color(0xD9FFFFFF));

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: theme.colorScheme.outlineVariant
                  .withOpacity(isDark ? 0.25 : 0.45),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
