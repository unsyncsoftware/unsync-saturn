import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/saturn_theme.dart';
import '../../mesh/providers/mesh_providers.dart';
import '../../mesh/services/mesh_search_service.dart';

class SaturnHome extends ConsumerStatefulWidget {
  const SaturnHome({super.key, required this.onNavigate});

  final ValueChanged<String> onNavigate;

  @override
  ConsumerState<SaturnHome> createState() => _SaturnHomeState();
}

class _SaturnHomeState extends ConsumerState<SaturnHome> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final trimmedQuery = _query.trim();
    final identity = ref.watch(meshIdentityProvider);
    final meshResults = trimmedQuery.isEmpty
        ? const AsyncValue<List<MeshSearchResult>>.data([])
        : ref.watch(meshSearchProvider(trimmedQuery));

    return ColoredBox(
      color: SaturnTheme.voidBg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 132,
                height: 92,
                child: CustomPaint(painter: _SaturnLogoPainter()),
              ),
              const SizedBox(height: 28),
              Text(
                'SATURN',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.meshAccent,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 8,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AppConstants.appTagline.toUpperCase(),
                textAlign: TextAlign.center,
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.textMuted,
                  fontSize: 10,
                  letterSpacing: 3,
                ),
              ),
              if (identity.isMeshLoggedIn && identity.handle != null) ...[
                const SizedBox(height: 18),
                _MeshIdentityBadge(handle: identity.handle!),
              ],
              const SizedBox(height: 28),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: TextField(
                  textInputAction: TextInputAction.search,
                  keyboardType: TextInputType.webSearch,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: SaturnTheme.mono.copyWith(
                    color: SaturnTheme.textPrimary,
                    fontSize: 14,
                  ),
                  cursorColor: SaturnTheme.meshAccent,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(
                      Icons.search,
                      color: SaturnTheme.textSecondary,
                    ),
                    hintText: 'Search Saturn or the web',
                    hintStyle: SaturnTheme.mono.copyWith(
                      color: SaturnTheme.textMuted,
                      fontSize: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: SaturnTheme.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: SaturnTheme.meshAccent,
                        width: 1.4,
                      ),
                    ),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                  onSubmitted: (value) {
                    final resolved = _resolveInput(value);
                    if (resolved != null) {
                      widget.onNavigate(resolved);
                    }
                  },
                ),
              ),
              const SizedBox(height: 16),
              _MeshSearchResults(
                query: trimmedQuery,
                results: meshResults,
                onNavigate: widget.onNavigate,
              ),
              const SizedBox(height: 18),
              Text(
                'Try: mesh://@bossing.site',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _QuickNavChip(
                    label: '@bossing.site',
                    onTap: () => widget.onNavigate('mesh://@bossing.site'),
                  ),
                  _QuickNavChip(
                    label: 'unsync.uk',
                    onTap: () => widget.onNavigate('https://unsync.uk'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _resolveInput(String input) {
    final value = input.trim();
    if (value.isEmpty) {
      return null;
    }

    if (value.startsWith(AppConstants.meshSchemePrefix) ||
        value.startsWith('http://') ||
        value.startsWith('https://')) {
      return value;
    }

    if (value.startsWith('@') ||
        value.endsWith('.site') && !value.contains(RegExp(r'\s'))) {
      return '${AppConstants.meshSchemePrefix}$value';
    }

    if (value.contains('.') && !value.contains(RegExp(r'\s'))) {
      return 'https://$value';
    }

    return '${AppConstants.fallbackSearch}${Uri.encodeQueryComponent(value)}';
  }
}

class _MeshSearchResults extends StatelessWidget {
  const _MeshSearchResults({
    required this.query,
    required this.results,
    required this.onNavigate,
  });

  final String query;
  final AsyncValue<List<MeshSearchResult>> results;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return const SizedBox.shrink();
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: results.when(
        data: (items) {
          if (items.isEmpty) {
            return const SizedBox.shrink();
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: items
                .map(
                  (item) => _MeshResultTile(
                    title: item.title,
                    subtitle: item.subtitle,
                    meshUrl: item.meshUrl,
                    onTap: () => onNavigate(item.meshUrl),
                  ),
                )
                .toList(growable: false),
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(
            minHeight: 2,
            color: SaturnTheme.meshAccent,
            backgroundColor: SaturnTheme.border,
          ),
        ),
        error: (_, _) => const SizedBox.shrink(),
      ),
    );
  }
}

class _MeshResultTile extends StatelessWidget {
  const _MeshResultTile({
    required this.title,
    required this.meshUrl,
    required this.onTap,
    this.subtitle,
  });

  final String title;
  final String meshUrl;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(Icons.hub_outlined, color: SaturnTheme.meshAccent),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: SaturnTheme.mono.copyWith(
          color: SaturnTheme.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        subtitle == null || subtitle == title ? meshUrl : '$subtitle\n$meshUrl',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: SaturnTheme.mono.copyWith(
          color: SaturnTheme.textSecondary,
          fontSize: 11,
        ),
      ),
      onTap: onTap,
    );
  }
}

class _MeshIdentityBadge extends StatelessWidget {
  const _MeshIdentityBadge({required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: SaturnTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: SaturnTheme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.hub_outlined,
              color: SaturnTheme.meshAccent,
              size: 16,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                handle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickNavChip extends StatelessWidget {
  const _QuickNavChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: SaturnTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: SaturnTheme.border),
        ),
        child: Text(
          label,
          style: SaturnTheme.mono.copyWith(
            color: SaturnTheme.textPrimary,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _SaturnLogoPainter extends CustomPainter {
  const _SaturnLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final planetRadius = size.height * 0.26;
    final planetFill = Paint()
      ..color = SaturnTheme.meshAccent.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    final planetStroke = Paint()
      ..color = SaturnTheme.meshAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final ringPaint = Paint()
      ..color = SaturnTheme.cyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-math.pi / 10);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: size.width * 0.88,
        height: size.height * 0.28,
      ),
      ringPaint,
    );
    canvas.restore();

    canvas.drawCircle(center, planetRadius, planetFill);
    canvas.drawCircle(center, planetRadius, planetStroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
