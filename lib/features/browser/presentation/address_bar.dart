import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/saturn_theme.dart';
import '../providers/browser_provider.dart';

class AddressBar extends ConsumerStatefulWidget {
  const AddressBar({super.key, required this.onSubmitted});

  final ValueChanged<String> onSubmitted;

  @override
  ConsumerState<AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends ConsumerState<AddressBar> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode = FocusNode()..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(browserProvider);
    if (!_focusNode.hasFocus && _controller.text != state.addressBarText) {
      _controller.text = state.addressBarText;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }

    final glows = _focusNode.hasFocus || state.isMeshPage;
    final isSecure = state.addressBarText.startsWith('https://');
    final icon = state.isMeshPage ? Icons.hub_outlined : Icons.lock_outline;

    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      textInputAction: TextInputAction.go,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      style: SaturnTheme.mono.copyWith(
        color: SaturnTheme.textPrimary,
        fontSize: 13,
      ),
      cursorColor: SaturnTheme.meshAccent,
      decoration: InputDecoration(
        prefixIcon: Icon(
          icon,
          size: 18,
          color: state.isMeshPage
              ? SaturnTheme.meshAccent
              : isSecure
              ? SaturnTheme.cyan
              : SaturnTheme.textSecondary,
        ),
        suffixIcon: state.isLoading
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : null,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(
            color: glows ? SaturnTheme.meshAccent : SaturnTheme.border,
            width: glows ? 1.4 : 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: const BorderSide(
            color: SaturnTheme.meshAccent,
            width: 1.4,
          ),
        ),
      ),
      onChanged: (value) {
        ref.read(browserProvider.notifier).setAddressBar(value);
      },
      onSubmitted: (value) {
        final resolved = _resolveInput(value);
        _focusNode.unfocus();
        widget.onSubmitted(resolved);
      },
    );
  }

  String _resolveInput(String input) {
    final value = input.trim();
    if (value.startsWith(AppConstants.meshSchemePrefix) ||
        value.startsWith('http://') ||
        value.startsWith('https://')) {
      return value;
    }

    if (value.startsWith('@')) {
      return '${AppConstants.meshSchemePrefix}$value';
    }

    if (value.contains('.') && !value.contains(RegExp(r'\s'))) {
      return 'https://$value';
    }

    return '${AppConstants.fallbackSearch}${Uri.encodeQueryComponent(value)}';
  }
}
