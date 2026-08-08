import 'package:flutter/material.dart';

import '../../core/theme/atlas_theme.dart';

/// Animated skeleton placeholder widget for loading states.
/// Shows a subtle pulsing shimmer effect.
class SkeletonLoader extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;

  const SkeletonLoader({
    super.key,
    this.width = double.infinity,
    this.height = 16,
    this.borderRadius = 6,
  });

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _anim = Tween<double>(begin: 0.3, end: 0.6).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _ctrl.reverse();
        } else if (status == AnimationStatus.dismissed) {
          _ctrl.forward();
        }
      });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: c.bgElevated.withValues(alpha: _anim.value),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      ),
    );
  }
}

/// A full skeleton card mimicking a server list row.
class SkeletonServerRow extends StatelessWidget {
  const SkeletonServerRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          // Flag/icon placeholder
          const SkeletonLoader(width: 28, height: 28, borderRadius: 4),
          const SizedBox(width: 12),
          // Name + subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                SkeletonLoader(width: 140, height: 12),
                SizedBox(height: 6),
                SkeletonLoader(width: 80, height: 9),
              ],
            ),
          ),
          // Latency badge
          const SkeletonLoader(width: 50, height: 18, borderRadius: 9),
          const SizedBox(width: 8),
          // Action icon
          const SkeletonLoader(width: 24, height: 24, borderRadius: 12),
        ],
      ),
    );
  }
}

/// A skeleton card mimicking a stats panel.
class SkeletonStatsCard extends StatelessWidget {
  const SkeletonStatsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SkeletonLoader(width: 100, height: 10),
          const SizedBox(height: 12),
          const SkeletonLoader(width: 180, height: 28, borderRadius: 4),
          const SizedBox(height: 16),
          Row(
            children: const [
              SkeletonLoader(width: 60, height: 8),
              SizedBox(width: 8),
              SkeletonLoader(width: 40, height: 8),
            ],
          ),
        ],
      ),
    );
  }
}

/// Wraps [child] with a shimmer skeleton if [loading] is true.
/// Otherwise shows [child] directly.
class SkeletonIfLoading extends StatelessWidget {
  final bool loading;
  final Widget child;
  final Widget skeleton;

  const SkeletonIfLoading({
    super.key,
    required this.loading,
    required this.child,
    required this.skeleton,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return skeleton;
    return child;
  }
}
