import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';

class BrowserState {
  const BrowserState({
    this.currentUrl = AppConstants.homeUrl,
    this.addressBarText = '',
    this.isLoading = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.loadProgress = 0,
    this.pageTitle,
    this.isMeshPage = false,
  });

  final String currentUrl;
  final String addressBarText;
  final bool isLoading;
  final bool canGoBack;
  final bool canGoForward;
  final double loadProgress;
  final String? pageTitle;
  final bool isMeshPage;

  BrowserState copyWith({
    String? currentUrl,
    String? addressBarText,
    bool? isLoading,
    bool? canGoBack,
    bool? canGoForward,
    double? loadProgress,
    String? pageTitle,
    bool clearTitle = false,
    bool? isMeshPage,
  }) {
    return BrowserState(
      currentUrl: currentUrl ?? this.currentUrl,
      addressBarText: addressBarText ?? this.addressBarText,
      isLoading: isLoading ?? this.isLoading,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      loadProgress: loadProgress ?? this.loadProgress,
      pageTitle: clearTitle ? null : pageTitle ?? this.pageTitle,
      isMeshPage: isMeshPage ?? this.isMeshPage,
    );
  }
}

class BrowserNotifier extends StateNotifier<BrowserState> {
  BrowserNotifier()
    : super(const BrowserState(addressBarText: AppConstants.homeUrl));

  void setUrl(String url) {
    state = state.copyWith(
      currentUrl: url,
      addressBarText: url,
      isMeshPage: url.startsWith(AppConstants.meshSchemePrefix),
    );
  }

  void setAddressBar(String text) {
    state = state.copyWith(
      addressBarText: text,
      isMeshPage: text.startsWith(AppConstants.meshSchemePrefix),
    );
  }

  void setLoading(bool isLoading, {double progress = 0}) {
    state = state.copyWith(
      isLoading: isLoading,
      loadProgress: isLoading ? progress : 1,
    );
  }

  void setProgress(double progress) {
    state = state.copyWith(loadProgress: progress.clamp(0, 1).toDouble());
  }

  void setNavState({bool? canGoBack, bool? canGoForward}) {
    state = state.copyWith(canGoBack: canGoBack, canGoForward: canGoForward);
  }

  void setTitle(String? title) {
    state = state.copyWith(pageTitle: title, clearTitle: title == null);
  }
}

final browserProvider = StateNotifierProvider<BrowserNotifier, BrowserState>(
  (ref) => BrowserNotifier(),
);
