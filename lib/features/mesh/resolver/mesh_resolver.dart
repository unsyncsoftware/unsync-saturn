import 'package:dio/dio.dart';

import '../../../core/constants/app_constants.dart';

enum MeshResolveStatus { success, notFound, timeout, error }

class MeshResolveResult {
  const MeshResolveResult({
    required this.status,
    this.targetUrl,
    this.handle,
    this.errorMessage,
    this.raw,
  });

  final MeshResolveStatus status;
  final String? targetUrl;
  final String? handle;
  final String? errorMessage;
  final Map<String, dynamic>? raw;
}

class MeshResolver {
  MeshResolver({Dio? dio})
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

  Future<MeshResolveResult> resolve(String meshUrl) async {
    final parsed = _parseMeshUrl(meshUrl);
    final handle = parsed?.handle;
    if (parsed == null || handle == null || handle.isEmpty) {
      return MeshResolveResult(
        status: MeshResolveStatus.error,
        errorMessage: 'Invalid mesh URL',
      );
    }

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        AppConstants.resolveEndpoint,
        queryParameters: {'handle': handle},
      );

      final raw = response.data ?? const <String, dynamic>{};
      final target = raw['target'];
      if (response.statusCode == 200 && target is String && target.isNotEmpty) {
        // TODO: Verify registry signatures before trusting target records.
        final isValid = _isSignatureValid(raw);
        if (!isValid) {
          return MeshResolveResult(
            status: MeshResolveStatus.error,
            handle: handle,
            raw: raw,
            errorMessage: 'Invalid mesh signature',
          );
        }

        return MeshResolveResult(
          status: MeshResolveStatus.success,
          targetUrl: _appendSuffix(target, parsed.suffix),
          handle: handle,
          raw: raw,
        );
      }

      return MeshResolveResult(
        status: MeshResolveStatus.error,
        handle: handle,
        raw: raw,
        errorMessage: 'Resolver returned no target',
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return MeshResolveResult(
          status: MeshResolveStatus.notFound,
          handle: handle,
          raw: _mapResponse(error.response?.data),
          errorMessage: 'Mesh handle not found',
        );
      }

      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return MeshResolveResult(
          status: MeshResolveStatus.timeout,
          handle: handle,
          errorMessage: 'Mesh resolve timed out',
        );
      }

      return MeshResolveResult(
        status: MeshResolveStatus.error,
        handle: handle,
        raw: _mapResponse(error.response?.data),
        errorMessage: error.message,
      );
    } catch (error) {
      return MeshResolveResult(
        status: MeshResolveStatus.error,
        handle: handle,
        errorMessage: error.toString(),
      );
    }
  }

  _ParsedMeshUrl? _parseMeshUrl(String input) {
    if (!input.startsWith(AppConstants.meshSchemePrefix)) {
      return null;
    }

    final withoutScheme = input.substring(AppConstants.meshSchemePrefix.length);
    if (withoutScheme.isEmpty) {
      return null;
    }

    final suffixStart = withoutScheme.indexOf(RegExp(r'[/#?]'));
    if (suffixStart == -1) {
      return _ParsedMeshUrl(handle: withoutScheme, suffix: '');
    }

    return _ParsedMeshUrl(
      handle: withoutScheme.substring(0, suffixStart),
      suffix: withoutScheme.substring(suffixStart),
    );
  }

  String _appendSuffix(String target, String suffix) {
    if (suffix.isEmpty) {
      return target;
    }

    final targetUri = Uri.parse(target);
    final suffixUri = Uri.parse('mesh://placeholder$suffix');
    final path = _joinPaths(targetUri.path, suffixUri.path);

    return targetUri
        .replace(
          path: path,
          query: suffixUri.hasQuery ? suffixUri.query : targetUri.query,
          fragment: suffixUri.hasFragment
              ? suffixUri.fragment
              : targetUri.fragment,
        )
        .toString();
  }

  String _joinPaths(String basePath, String suffixPath) {
    if (suffixPath.isEmpty) {
      return basePath;
    }

    if (basePath.isEmpty || basePath == '/') {
      return suffixPath;
    }

    final cleanBase = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    return '$cleanBase$suffixPath';
  }

  Map<String, dynamic>? _mapResponse(Object? data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    return null;
  }

  bool _isSignatureValid(Map<String, dynamic> raw) {
    return true;
  }
}

class _ParsedMeshUrl {
  const _ParsedMeshUrl({required this.handle, required this.suffix});

  final String handle;
  final String suffix;
}
