import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/saturn_theme.dart';
import '../../mesh/resolver/mesh_resolver.dart';
import '../../mesh/providers/mesh_providers.dart';
import '../../mesh/services/mesh_client.dart';
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
  String? _currentHostPeerId;
  String? _currentMeshHandle;

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
                        if (url == null) {
                          return NavigationActionPolicy.ALLOW;
                        }

                        if (url.startsWith(AppConstants.meshSchemePrefix)) {
                          final hostPeerId = _currentHostPeerId;
                          if (hostPeerId != null && _isCurrentMeshHandle(url)) {
                            await _fetchMeshContent(
                              hostPeerId,
                              _pathFromMeshUrl(url),
                              url,
                            );
                          } else {
                            await _resolveMesh(url);
                          }
                          return NavigationActionPolicy.CANCEL;
                        }

                        final meshUrl = _meshUrlForRelativeNavigation(url);
                        if (meshUrl != null && _currentHostPeerId != null) {
                          await _fetchMeshContent(
                            _currentHostPeerId!,
                            _pathFromMeshUrl(meshUrl),
                            meshUrl,
                          );
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
      _clearCurrentMeshHost();
      setState(() => _showHome = true);
      notifier.setLoading(false);
      notifier.setNavState(canGoBack: false, canGoForward: false);
      return;
    }

    if (url.startsWith(AppConstants.meshSchemePrefix)) {
      await _resolveMesh(url);
      return;
    }

    _clearCurrentMeshHost();
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

    if (result.status == MeshResolveStatus.success && result.peerId != null) {
      _currentHostPeerId = result.peerId;
      _currentMeshHandle = result.handle;
      await _fetchMeshContent(
        result.peerId!,
        _pathFromMeshUrl(meshUrl),
        meshUrl,
      );
      return;
    }

    _clearCurrentMeshHost();
    notifier.setLoading(false);
    _showMeshError(result);
  }

  Future<void> _fetchMeshContent(
    String hostPeerId,
    String path,
    String displayUrl,
  ) async {
    final notifier = ref.read(browserProvider.notifier);
    notifier.setAddressBar(displayUrl);
    notifier.setLoading(true);
    setState(() => _showHome = false);

    final result = await ref.read(meshClientProvider).fetch(hostPeerId, path);
    if (!mounted) {
      return;
    }

    if (result.success && result.bytes != null) {
      try {
        await _webViewController?.loadData(
          data: utf8.decode(result.bytes!),
          mimeType: result.mime,
          encoding: 'UTF-8',
          baseUrl: WebUri(displayUrl),
          historyUrl: WebUri(displayUrl),
        );
        notifier.setAddressBar(displayUrl);
      } on FormatException catch (error) {
        notifier.setLoading(false);
        _showMeshFetchError(
          MeshFetchResult(
            success: false,
            status: result.status,
            mime: result.mime,
            error: error.message,
          ),
        );
      }
      return;
    }

    notifier.setLoading(false);
    _showMeshFetchError(result);
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

  void _showMeshFetchError(MeshFetchResult result) {
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
                'Mesh fetch failed',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: SaturnTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Status: ${result.status}',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.meshAccent,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'MIME: ${result.mime}',
                style: SaturnTheme.mono.copyWith(
                  color: SaturnTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              if (result.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  result.error!,
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

  bool _isCurrentMeshHandle(String meshUrl) {
    final handle = _handleFromMeshUrl(meshUrl);
    return handle != null && handle == _currentMeshHandle;
  }

  String? _meshUrlForRelativeNavigation(String url) {
    final handle = _currentMeshHandle;
    if (handle == null) {
      return null;
    }

    if (url.startsWith('about:blank')) {
      final suffix = url.substring('about:blank'.length);
      if (suffix.startsWith('/')) {
        return '${AppConstants.meshSchemePrefix}$handle$suffix';
      }
      if (suffix.startsWith('?')) {
        return '${AppConstants.meshSchemePrefix}$handle/$suffix';
      }
    }

    if (url.startsWith('/')) {
      return '${AppConstants.meshSchemePrefix}$handle$url';
    }

    return null;
  }

  String _pathFromMeshUrl(String meshUrl) {
    final withoutScheme = meshUrl.startsWith(AppConstants.meshSchemePrefix)
        ? meshUrl.substring(AppConstants.meshSchemePrefix.length)
        : meshUrl;
    final suffixStart = withoutScheme.indexOf(RegExp(r'[/#?]'));
    if (suffixStart == -1) {
      return '/';
    }

    final suffix = withoutScheme.substring(suffixStart);
    if (suffix.startsWith('/')) {
      final fragmentStart = suffix.indexOf('#');
      final path = fragmentStart == -1
          ? suffix
          : suffix.substring(0, fragmentStart);
      return path.isEmpty ? '/' : path;
    }

    if (suffix.startsWith('?')) {
      final fragmentStart = suffix.indexOf('#');
      final query = fragmentStart == -1
          ? suffix
          : suffix.substring(0, fragmentStart);
      return '/$query';
    }

    return '/';
  }

  String? _handleFromMeshUrl(String meshUrl) {
    if (!meshUrl.startsWith(AppConstants.meshSchemePrefix)) {
      return null;
    }

    final withoutScheme = meshUrl.substring(
      AppConstants.meshSchemePrefix.length,
    );
    final suffixStart = withoutScheme.indexOf(RegExp(r'[/#?]'));
    final handle = suffixStart == -1
        ? withoutScheme
        : withoutScheme.substring(0, suffixStart);
    return handle.isEmpty ? null : handle;
  }

  void _clearCurrentMeshHost() {
    _currentHostPeerId = null;
    _currentMeshHandle = null;
  }
}
