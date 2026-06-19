import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/saturn_theme.dart';
import '../providers/browser_provider.dart';

class BrowserControls extends ConsumerWidget {
  const BrowserControls({
    super.key,
    required this.onBack,
    required this.onForward,
    required this.onReloadOrStop,
    required this.onHome,
  });

  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReloadOrStop;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(browserProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ControlButton(
          icon: Icons.arrow_back,
          enabled: state.canGoBack,
          onPressed: onBack,
        ),
        _ControlButton(
          icon: Icons.arrow_forward,
          enabled: state.canGoForward,
          onPressed: onForward,
        ),
        _ControlButton(
          icon: state.isLoading ? Icons.close : Icons.refresh,
          color: state.isLoading ? SaturnTheme.error : null,
          onPressed: onReloadOrStop,
        ),
        _ControlButton(icon: Icons.home_outlined, onPressed: onHome),
      ],
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.onPressed,
    this.enabled = true,
    this.color,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        icon,
        color: enabled
            ? color ?? SaturnTheme.textSecondary
            : SaturnTheme.textMuted,
        size: 20,
      ),
    );
  }
}
