import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';

class BrowserTab {
  const BrowserTab({
    required this.id,
    this.title = 'New tab',
    this.currentUrl = AppConstants.homeUrl,
    this.addressBarText = '',
    this.canGoBack = false,
    this.canGoForward = false,
    this.isLoading = false,
    this.loadProgress = 0,
  });

  final String id;
  final String title;
  final String currentUrl;
  final String addressBarText;
  final bool canGoBack;
  final bool canGoForward;
  final bool isLoading;
  final double loadProgress;

  bool get isMeshPage =>
      currentUrl.startsWith(AppConstants.meshSchemePrefix) ||
      addressBarText.startsWith(AppConstants.meshSchemePrefix);

  BrowserTab copyWith({
    String? title,
    String? currentUrl,
    String? addressBarText,
    bool? canGoBack,
    bool? canGoForward,
    bool? isLoading,
    double? loadProgress,
  }) {
    return BrowserTab(
      id: id,
      title: title ?? this.title,
      currentUrl: currentUrl ?? this.currentUrl,
      addressBarText: addressBarText ?? this.addressBarText,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      isLoading: isLoading ?? this.isLoading,
      loadProgress: loadProgress ?? this.loadProgress,
    );
  }
}

class BrowserState {
  const BrowserState({
    this.tabs = const [BrowserTab(id: 'tab-1')],
    this.activeTabId = 'tab-1',
  });

  final List<BrowserTab> tabs;
  final String activeTabId;

  BrowserTab get activeTab {
    for (final tab in tabs) {
      if (tab.id == activeTabId) {
        return tab;
      }
    }
    return tabs.first;
  }

  String get currentUrl => activeTab.currentUrl;
  String get addressBarText => activeTab.addressBarText;
  bool get isLoading => activeTab.isLoading;
  bool get canGoBack => activeTab.canGoBack;
  bool get canGoForward => activeTab.canGoForward;
  double get loadProgress => activeTab.loadProgress;
  String get pageTitle => activeTab.title;
  bool get isMeshPage => activeTab.isMeshPage;

  BrowserState copyWith({List<BrowserTab>? tabs, String? activeTabId}) {
    return BrowserState(
      tabs: tabs ?? this.tabs,
      activeTabId: activeTabId ?? this.activeTabId,
    );
  }
}

class BrowserNotifier extends StateNotifier<BrowserState> {
  BrowserNotifier() : super(const BrowserState());

  int _nextTabNumber = 2;

  String newTab() {
    final id = 'tab-${_nextTabNumber++}';
    state = BrowserState(
      tabs: [
        ...state.tabs,
        BrowserTab(id: id),
      ],
      activeTabId: id,
    );
    return id;
  }

  void closeTab(String id) {
    if (state.tabs.length == 1) {
      final replacementId = 'tab-${_nextTabNumber++}';
      state = BrowserState(
        tabs: [BrowserTab(id: replacementId)],
        activeTabId: replacementId,
      );
      return;
    }

    final tabIndex = state.tabs.indexWhere((tab) => tab.id == id);
    if (tabIndex == -1) {
      return;
    }

    final nextTabs = state.tabs.where((tab) => tab.id != id).toList();
    var nextActiveId = state.activeTabId;
    if (id == state.activeTabId) {
      final nextIndex = tabIndex.clamp(0, nextTabs.length - 1).toInt();
      nextActiveId = nextTabs[nextIndex].id;
    }

    state = BrowserState(tabs: nextTabs, activeTabId: nextActiveId);
  }

  void switchTab(String id) {
    if (state.activeTabId == id || !state.tabs.any((tab) => tab.id == id)) {
      return;
    }

    state = state.copyWith(activeTabId: id);
  }

  void setUrl(String url) {
    final isHome = url == AppConstants.homeUrl;
    _updateActiveTab(
      (tab) => tab.copyWith(
        currentUrl: url,
        addressBarText: isHome ? '' : url,
        title: isHome ? 'New tab' : tab.title,
      ),
    );
  }

  void setAddressBar(String text) {
    _updateActiveTab((tab) => tab.copyWith(addressBarText: text));
  }

  void setLoading(bool isLoading, {double progress = 0}) {
    _updateActiveTab(
      (tab) => tab.copyWith(
        isLoading: isLoading,
        loadProgress: isLoading ? progress : 1,
      ),
    );
  }

  void setProgress(double progress) {
    _updateActiveTab(
      (tab) => tab.copyWith(loadProgress: progress.clamp(0, 1).toDouble()),
    );
  }

  void setNavState({bool? canGoBack, bool? canGoForward}) {
    _updateActiveTab(
      (tab) => tab.copyWith(canGoBack: canGoBack, canGoForward: canGoForward),
    );
  }

  void setTitle(String? title) {
    final normalized = title == null || title.trim().isEmpty
        ? _titleForUrl(state.currentUrl)
        : title.trim();
    _updateActiveTab((tab) => tab.copyWith(title: normalized));
  }

  void _updateActiveTab(BrowserTab Function(BrowserTab tab) update) {
    state = state.copyWith(
      tabs: [
        for (final tab in state.tabs)
          if (tab.id == state.activeTabId) update(tab) else tab,
      ],
    );
  }

  String _titleForUrl(String url) {
    if (url == AppConstants.homeUrl) {
      return 'New tab';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return url;
    }
    return uri.host;
  }
}

final browserProvider = StateNotifierProvider<BrowserNotifier, BrowserState>(
  (ref) => BrowserNotifier(),
);
