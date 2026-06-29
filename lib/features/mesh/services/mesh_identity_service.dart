import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/constants/app_constants.dart';

const List<int> _ed25519SpkiPrefix = [
  0x30,
  0x2a,
  0x30,
  0x05,
  0x06,
  0x03,
  0x2b,
  0x65,
  0x70,
  0x03,
  0x21,
  0x00,
];

bool _isRegistrationFresh(DateTime? value) {
  if (value == null) {
    return false;
  }
  return DateTime.now().toUtc().difference(value.toUtc()) <
      const Duration(seconds: 3600);
}

class MeshIdentityState {
  const MeshIdentityState({
    this.handle,
    this.peerId,
    this.publicKey,
    this.privateKey,
    this.isLoaded = false,
    this.isRegistered = false,
    this.lastRegisteredAt,
    this.errorMessage,
  });

  final String? handle;
  final String? peerId;
  final String? publicKey;
  final String? privateKey;
  final bool isLoaded;
  final bool isRegistered;
  final DateTime? lastRegisteredAt;
  final String? errorMessage;

  bool get isMeshLoggedIn =>
      isLoaded &&
      isRegistered &&
      handle != null &&
      handle!.isNotEmpty &&
      peerId != null &&
      peerId!.isNotEmpty &&
      publicKey != null &&
      publicKey!.isNotEmpty &&
      privateKey != null &&
      privateKey!.isNotEmpty &&
      lastRegisteredAt != null &&
      _isRegistrationFresh(lastRegisteredAt!);

  MeshIdentityState copyWith({
    String? handle,
    String? peerId,
    String? publicKey,
    String? privateKey,
    bool? isLoaded,
    bool? isRegistered,
    DateTime? lastRegisteredAt,
    String? errorMessage,
    bool clearError = false,
  }) {
    return MeshIdentityState(
      handle: handle ?? this.handle,
      peerId: peerId ?? this.peerId,
      publicKey: publicKey ?? this.publicKey,
      privateKey: privateKey ?? this.privateKey,
      isLoaded: isLoaded ?? this.isLoaded,
      isRegistered: isRegistered ?? this.isRegistered,
      lastRegisteredAt: lastRegisteredAt ?? this.lastRegisteredAt,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class MeshIdentityService extends StateNotifier<MeshIdentityState> {
  MeshIdentityService({Dio? dio, FlutterSecureStorage? secureStorage})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: AppConstants.connectTimeout,
              receiveTimeout: AppConstants.resolveTimeout,
              sendTimeout: AppConstants.resolveTimeout,
              contentType: Headers.jsonContentType,
            ),
          ),
      _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      super(const MeshIdentityState()) {
    _loaded = _load();
  }

  static const _identityKey = 'mesh_identity_bundle';
  static const _ttl = 3600;
  static final Random _random = Random.secure();
  static final Ed25519 _ed25519 = Ed25519();

  final Dio _dio;
  final FlutterSecureStorage _secureStorage;
  late final Future<void> _loaded;

  Future<void> ensureLoaded() => _loaded;

  Future<bool> ensureRegistered() async {
    await ensureLoaded();
    if (state.isMeshLoggedIn) {
      return true;
    }

    if (state.handle == null ||
        state.peerId == null ||
        state.publicKey == null ||
        state.privateKey == null) {
      return false;
    }

    return _registerAndSave(
      state.copyWith(isRegistered: false, clearError: true),
    );
  }

  Future<bool> createIdentity({String? handle}) async {
    await ensureLoaded();

    final keyPair = await _ed25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final identityHandle =
        _normalizeHandle(handle) ?? '@saturn-${_randomHex(4)}';
    final identity = MeshIdentityState(
      handle: identityHandle,
      peerId: 'saturn-${_randomHex(16)}',
      publicKey: _encodeEd25519Spki(publicKey.bytes),
      privateKey: base64Encode(privateKeyBytes),
      isLoaded: true,
    );

    return _registerAndSave(identity);
  }

  Future<bool> logInWithExistingHandle(String _) async {
    await ensureLoaded();
    state = state.copyWith(
      isRegistered: false,
      errorMessage:
          'Existing handle login requires importing the identity private key. Handle-only login is disabled.',
    );
    return false;
  }

  Future<bool> _registerAndSave(MeshIdentityState identity) async {
    final handle = identity.handle;
    final peerId = identity.peerId;
    final publicKey = _normalizePublicKey(identity.publicKey);
    final privateKey = identity.privateKey;
    if (handle == null ||
        peerId == null ||
        publicKey.isEmpty ||
        privateKey == null) {
      state = state.copyWith(
        isLoaded: true,
        isRegistered: false,
        errorMessage: 'Identity is incomplete.',
      );
      return false;
    }
    identity = identity.copyWith(publicKey: publicKey);

    final expiresAt =
        DateTime.now()
            .toUtc()
            .add(const Duration(seconds: _ttl))
            .millisecondsSinceEpoch ~/
        1000;
    final signature = await _signRegistration(
      handle: handle,
      peerId: peerId,
      publicKey: publicKey,
      privateKey: privateKey,
      expiresAt: expiresAt,
    );

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        AppConstants.registerEndpoint,
        data: {
          'handle': handle,
          'peer_id': peerId,
          'pubkey': publicKey,
          'expires_at': expiresAt,
          'ttl': _ttl,
          'signature': signature,
        },
      );

      if ((response.statusCode ?? 500) >= 400) {
        state = identity.copyWith(
          isRegistered: false,
          errorMessage: 'Mesh registry rejected identity registration.',
        );
        return false;
      }

      final registered = identity.copyWith(
        isLoaded: true,
        isRegistered: true,
        lastRegisteredAt: DateTime.now().toUtc(),
        clearError: true,
      );
      await _save(registered);
      state = registered;
      return true;
    } on DioException catch (error) {
      state = identity.copyWith(
        isLoaded: true,
        isRegistered: false,
        errorMessage: _registrationError(error),
      );
      return false;
    } catch (error) {
      state = identity.copyWith(
        isLoaded: true,
        isRegistered: false,
        errorMessage: error.toString(),
      );
      return false;
    }
  }

  Future<String> _signRegistration({
    required String handle,
    required String peerId,
    required String publicKey,
    required String privateKey,
    required int expiresAt,
  }) async {
    final publicKeyBytes = _rawEd25519PublicKey(publicKey);
    final keyPair = SimpleKeyPairData(
      base64Decode(privateKey),
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
    final payload = '$handle|$peerId|$publicKey|$expiresAt';
    final signature = await _ed25519.sign(
      utf8.encode(payload),
      keyPair: keyPair,
    );
    return _base64UrlNoPadding(signature.bytes);
  }

  Future<void> _load() async {
    final encoded = await _secureStorage.read(key: _identityKey);
    if (encoded == null || encoded.isEmpty) {
      state = const MeshIdentityState(isLoaded: true);
      return;
    }

    try {
      final raw = jsonDecode(encoded);
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Identity bundle was not an object.');
      }

      state = MeshIdentityState(
        handle: _stringValue(raw['handle']),
        peerId: _stringValue(raw['peerId']),
        publicKey: _stringValue(raw['publicKey']),
        privateKey: _stringValue(raw['privateKey']),
        isLoaded: true,
        isRegistered:
            raw['isRegistered'] == true &&
            _isRegistrationFresh(_dateValue(raw['lastRegisteredAt'])),
        lastRegisteredAt: _dateValue(raw['lastRegisteredAt']),
      );
    } on FormatException catch (error) {
      state = MeshIdentityState(
        isLoaded: true,
        isRegistered: false,
        errorMessage: error.message,
      );
    }
  }

  Future<void> _save(MeshIdentityState identity) async {
    await _secureStorage.write(
      key: _identityKey,
      value: jsonEncode({
        'handle': identity.handle,
        'peerId': identity.peerId,
        'publicKey': identity.publicKey,
        'privateKey': identity.privateKey,
        'isRegistered': identity.isRegistered,
        'lastRegisteredAt': identity.lastRegisteredAt?.toIso8601String(),
      }),
    );
  }

  String _registrationError(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      final message = data['error'] ?? data['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }
    return error.message ?? 'Mesh registry registration failed.';
  }

  static String? _stringValue(Object? value) {
    return value is String && value.isNotEmpty ? value : null;
  }

  static DateTime? _dateValue(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  static String? _normalizeHandle(String? handle) {
    final trimmed = handle?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }

    final withoutPrefix = trimmed.startsWith('@')
        ? trimmed.substring(1).trim()
        : trimmed;
    if (withoutPrefix.isEmpty) {
      return null;
    }

    return '@$withoutPrefix';
  }

  static String _normalizePublicKey(String? publicKey) {
    if (publicKey == null || publicKey.isEmpty) {
      return '';
    }

    return _encodeEd25519Spki(_rawEd25519PublicKey(publicKey));
  }

  static String _encodeEd25519Spki(List<int> rawPublicKey) {
    return _base64UrlNoPadding([..._ed25519SpkiPrefix, ...rawPublicKey]);
  }

  static List<int> _rawEd25519PublicKey(String encodedPublicKey) {
    final bytes = base64Url.decode(_withBase64Padding(encodedPublicKey));
    if (bytes.length == 32) {
      return bytes;
    }

    if (bytes.length == _ed25519SpkiPrefix.length + 32) {
      for (var index = 0; index < _ed25519SpkiPrefix.length; index++) {
        if (bytes[index] != _ed25519SpkiPrefix[index]) {
          throw const FormatException('Invalid Ed25519 SPKI public key.');
        }
      }
      return bytes.sublist(_ed25519SpkiPrefix.length);
    }

    throw const FormatException('Invalid Ed25519 public key length.');
  }

  static String _base64UrlNoPadding(List<int> bytes) {
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _withBase64Padding(String value) {
    final remainder = value.length % 4;
    if (remainder == 0) {
      return value;
    }
    return value.padRight(value.length + 4 - remainder, '=');
  }

  static String _randomHex(int bytes) {
    final buffer = StringBuffer();
    for (var index = 0; index < bytes; index++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
