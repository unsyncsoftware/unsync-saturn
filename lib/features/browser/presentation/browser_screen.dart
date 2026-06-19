import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/saturn_theme.dart';
import '../../mesh/resolver/mesh_resolver.dart';
import '../../mesh/providers/mesh_providers.dart';
import '../providers/browser_provider.dart';
import 'address_bar.dart';
import 'browser_controls.dart';
import 'saturn_home.dart';

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  InAppWebViewController? _webViewController;
  bool _showHome = true;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(browserProvider);

    return Scaffold(
      backgroundColor: SaturnTheme.voidBg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: SaturnTheme.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
                    child: Row(
                      children: [
                        BrowserControls(
                          onBack: _goBack,
                          onForward: _goForward,
                          onReloadOrStop: _reloadOrStop,
                          onHome: () => _navigate(AppConstants.homeUrl),
                        ),
                        Expanded(child: AddressBar(onSubmitted: _navigate)),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          splashRadius: 18,
                          onPressed: () {},
                          icon: const Icon(
                            Icons.more_vert,
                            color: SaturnTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (state.isLoading)
                    LinearProgressIndicator(
                      minHeight: 2,
                      value: state.loadProgress <= 0
                          ? null
                          : state.loadProgress,
                      color: state.isMeshPage
                          ? SaturnTheme.meshAccent
                          : SaturnTheme.cyan,
                      backgroundColor: SaturnTheme.border,
                    ),
                  const Divider(height: 1),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  SaturnHome(onNavigate: _navigate),
                  Offstage(
                    offstage: _showHome,
                    child: InAppWebView(
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        useShouldOverrideUrlLoading: true,
                        mixedContentMode:
                            MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                        hardwareAcceleration: true,
                      ),
                      onWebViewCreated: (controller) {
                        _webViewController = controller;
                      },
                      shouldOverrideUrlLoading: (controller, action) async {
                        final url = action.request.url?.toString();
                        if (url != null &&
                            url.startsWith(AppConstants.meshSchemePrefix)) {
                          await _resolveMesh(url);
                          return NavigationActionPolicy.CANCEL;
                        }

                        return NavigationActionPolicy.ALLOW;
                      },
                      onLoadStart: (controller, url) {
                        ref
                            .read(browserProvider.notifier)
                            .setLoading(true, progress: 0);
                        if (url != null &&
                            !ref
                                .read(browserProvider)
                                .addressBarText
                                .startsWith(AppConstants.meshSchemePrefix)) {
                          ref
                              .read(browserProvider.notifier)
                              .setAddressBar(url.toString());
                        }
                      },
                      onProgressChanged: (controller, progress) {
                        ref
                            .read(browserProvider.notifier)
                            .setProgress(progress / 100);
                      },
                      onTitleChanged: (controller, title) {
                        ref.read(browserProvider.notifier).setTitle(title);
                      },
                      onLoadStop: (controller, url) async {
                        final notifier = ref.read(browserProvider.notifier);
                        notifier.setLoading(false);
                        notifier.setNavState(
                          canGoBack: await controller.canGoBack(),
                          canGoForward: await controller.canGoForward(),
                        );
                      },
                      onReceivedError: (controller, request, error) {
                        ref.read(browserProvider.notifier).setLoading(false);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _navigate(String url) async {
    final notifier = ref.read(browserProvider.notifier);
    notifier.setUrl(url);

    if (url == AppConstants.homeUrl) {
      setState(() => _showHome = true);
      notifier.setLoading(false);
      notifier.setNavState(canGoBack: false, canGoForward: false);
      return;
    }

    if (url.startsWith(AppConstants.meshSchemePrefix)) {
      await _resolveMesh(url);
      return;
    }

    setState(() => _showHome = false);
    await _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _resolveMesh(String meshUrl) async {
    final notifier = ref.read(browserProvider.notifier);
    notifier.setAddressBar(meshUrl);
    notifier.setLoading(true);
    setState(() => _showHome = false);

    final result = await ref.read(meshResolverProvider).resolve(meshUrl);
    if (!mounted) {
      return;
    }

    if (result.status == MeshResolveStatus.success &&
        result.targetUrl != null) {
      await _webViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(result.targetUrl!)),
      );
      notifier.setAddressBar(meshUrl);
      return;
    }

    notifier.setLoading(false);
    _showMeshError(result);
  }

  Future<void> _goBack() async {
    if (await _webViewController?.canGoBack() ?? false) {
      await _webViewController?.goBack();
    }
  }

  Future<void> _goForward() async {
    if (await _webViewController?.canGoForward() ?? false) {
      await _webViewController?.goForward();
    }
  }

  Future<void> _reloadOrStop() async {
    final state = ref.read(browserProvider);
    if (state.isLoading) {
      await _webViewController?.stopLoading();
      ref.read(browserProvider.notifier).setLoading(false);
    } else if (_showHome) {
      await _navigate(AppConstants.homeUrl);
    } else {
      await _webViewController?.reload();
    }
  }

  void _showMeshError(MeshResolveResult result) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SaturnTheme.surface,
      barrierColor: Colors.black54,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mesh resolve failed',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: SaturnTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Status: ${result.status.name}',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.meshAccent,
                  fontSize: 13,
                ),
              ),
              if (result.handle != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Handle: ${result.handle}',
                  style: SaturnTheme.mono.copyWith(
                    color: SaturnTheme.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
              if (result.errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  result.errorMessage!,
                  style: const TextStyle(color: SaturnTheme.textSecondary),
                ),
              ],
              const SizedBox(height: 18),
            ],
          ),
        );
      },
    );
  }
}
