import 'package:dio/dio.dart';

import '../../../core/constants/app_constants.dart';

class MeshSearchResult {
  const MeshSearchResult({
    required this.title,
    required this.meshUrl,
    this.subtitle,
  });

  final String title;
  final String meshUrl;
  final String? subtitle;

  factory MeshSearchResult.fromJson(Map<String, dynamic> raw) {
    final meshUrl = _meshUrlFrom(raw);
    final title = _firstString(raw, const [
      'title',
      'name',
      'display_name',
      'handle',
      'site',
    ]);

    return MeshSearchResult(
      title: title ?? meshUrl.substring(AppConstants.meshSchemePrefix.length),
      meshUrl: meshUrl,
      subtitle: _firstString(raw, const [
        'description',
        'summary',
        'bio',
        'handle',
        'site',
      ]),
    );
  }

  static String _meshUrlFrom(Map<String, dynamic> raw) {
    final url = _firstString(raw, const ['mesh_url', 'meshUrl', 'url']);
    if (url != null && url.startsWith(AppConstants.meshSchemePrefix)) {
      return url;
    }

    final handle = _firstString(raw, const ['handle', 'site', 'name']);
    final target = handle == null || handle.startsWith('@')
        ? handle
        : handle.endsWith('.site')
        ? handle
        : '@$handle';
    return '${AppConstants.meshSchemePrefix}${target ?? ''}';
  }

  static String? _firstString(Map<String, dynamic> raw, List<String> keys) {
    for (final key in keys) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }
}

class MeshSearchService {
  MeshSearchService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: AppConstants.connectTimeout,
              receiveTimeout: AppConstants.resolveTimeout,
              sendTimeout: AppConstants.resolveTimeout,
            ),
          );

  final Dio _dio;

  Future<List<MeshSearchResult>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    final response = await _dio.get<dynamic>(
      AppConstants.meshSearchEndpoint,
      queryParameters: {'q': trimmed},
    );
    return _parseResults(response.data);
  }

  List<MeshSearchResult> _parseResults(Object? data) {
    final rawResults = switch (data) {
      List<dynamic> value => value,
      Map<String, dynamic> value => _resultsFromMap(value),
      _ => const <dynamic>[],
    };

    return rawResults
        .whereType<Map<String, dynamic>>()
        .map(MeshSearchResult.fromJson)
        .where((result) => result.meshUrl != AppConstants.meshSchemePrefix)
        .toList(growable: false);
  }

  List<dynamic> _resultsFromMap(Map<String, dynamic> raw) {
    for (final key in const ['results', 'items', 'sites', 'users']) {
      final value = raw[key];
      if (value is List<dynamic>) {
        return value;
      }
    }
    return const [];
  }
}
