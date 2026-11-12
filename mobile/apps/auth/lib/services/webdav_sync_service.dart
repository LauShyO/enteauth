// Local addition (enteauth slice): WebDAV sync for offline mode.
//
// One encrypted vault file on a WebDAV server holds the whole offline
// library: per-code records keyed by stable sync ids, deletion tombstones,
// and gallery icon images. The vault is encrypted with a sync-password
// derived key (Argon2id via CryptoUtil.deriveSensitiveKey, same envelope as
// EnteAuthExport), so the server only ever sees ciphertext.
//
// Merge rule: per sync id the newer updatedAt wins; a tombstone at or after
// the entity's updatedAt deletes it. Sync runs only in offline mode — in
// online mode Ente's own sync owns the data.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/events/codes_updated_event.dart';
import 'package:ente_auth/models/export/ente.dart';
import 'package:ente_auth/models/webdav_vault.dart';
import 'package:ente_auth/services/authenticator_service.dart';
import 'package:ente_auth/services/code_icon_store.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_events/event_bus.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WebdavSyncException implements Exception {
  final String message;
  final bool wrongPassword;

  const WebdavSyncException(this.message, {this.wrongPassword = false});

  @override
  String toString() => 'WebdavSyncException: $message';
}

class WebdavSyncResult {
  final bool success;
  final String message;
  final int remoteApplied;
  final int localPushed;
  final int iconErrors;

  const WebdavSyncResult({
    required this.success,
    required this.message,
    this.remoteApplied = 0,
    this.localPushed = 0,
    this.iconErrors = 0,
  });
}

class WebdavTestResult {
  final bool reachable;
  final bool fileExists;
  final String message;

  const WebdavTestResult({
    required this.reachable,
    required this.fileExists,
    required this.message,
  });
}

class WebdavSyncService {
  WebdavSyncService._privateConstructor();

  static final WebdavSyncService instance =
      WebdavSyncService._privateConstructor();

  final _logger = Logger('WebdavSyncService');
  late SharedPreferences _prefs;
  late Dio _dio;

  static const String defaultRemotePath = 'ente-auth-webdav-sync.json';

  static const _keyEnabled = 'webdav_sync_enabled';
  static const _keyAutoSync = 'webdav_sync_auto';
  static const _keyServerUrl = 'webdav_sync_server_url';
  static const _keyUsername = 'webdav_sync_username';
  static const _keyRemotePath = 'webdav_sync_remote_path';
  static const _keyLastSyncAt = 'webdav_sync_last_at';
  static const _keyLastMessage = 'webdav_sync_last_message';

  Future<WebdavSyncResult>? _syncInFlight;
  bool _syncRerunRequested = false;
  Timer? _autoSyncTimer;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 60),
        validateStatus: (_) => true,
      ),
    );
    Bus.instance.on<CodesUpdatedEvent>().listen((_) => _scheduleAutoSync());
    _initialized = true;
    if (isEnabled && autoSync) {
      _scheduleAutoSync(initialDelay: const Duration(seconds: 3));
    }
  }

  bool get isEnabled => _prefs.getBool(_keyEnabled) ?? false;
  bool get autoSync => _prefs.getBool(_keyAutoSync) ?? true;
  String get serverUrl => _prefs.getString(_keyServerUrl) ?? '';
  String get username => _prefs.getString(_keyUsername) ?? '';
  String get remotePath =>
      _prefs.getString(_keyRemotePath) ?? defaultRemotePath;
  int? get lastSyncAtMs => _prefs.getInt(_keyLastSyncAt);
  String get lastMessage => _prefs.getString(_keyLastMessage) ?? '';

  Future<void> setEnabled(bool value) async {
    await _prefs.setBool(_keyEnabled, value);
  }

  Future<void> setAutoSync(bool value) async {
    await _prefs.setBool(_keyAutoSync, value);
  }

  Future<void> saveConfig({
    required String serverUrl,
    required String username,
    required String remotePath,
  }) async {
    await _prefs.setString(_keyServerUrl, serverUrl.trim());
    await _prefs.setString(_keyUsername, username.trim());
    final path = remotePath.trim();
    await _prefs.setString(
      _keyRemotePath,
      path.isEmpty ? defaultRemotePath : path,
    );
  }

  Future<bool> get hasWebdavPassword async =>
      (await Configuration.instance.getWebdavPassword())?.isNotEmpty ?? false;

  Future<bool> get hasSyncPassword async =>
      (await Configuration.instance.getWebdavSyncPassword())?.isNotEmpty ??
      false;

  bool get isConfigComplete {
    return serverUrl.isNotEmpty &&
        username.isNotEmpty &&
        remotePath.isNotEmpty;
  }

  void _scheduleAutoSync({Duration initialDelay = const Duration(seconds: 5)}) {
    if (!isEnabled || !autoSync) return;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(initialDelay, () {
      syncNow().ignore();
    });
  }

  Future<WebdavSyncResult> syncNow({bool isManual = false}) {
    final inFlight = _syncInFlight;
    if (inFlight != null) {
      _syncRerunRequested = true;
      return inFlight;
    }
    final completer = Completer<WebdavSyncResult>();
    _syncInFlight = completer.future;
    unawaited(_runCoalescedSync(completer, isManual: isManual));
    return completer.future;
  }

  Future<void> _runCoalescedSync(
    Completer<WebdavSyncResult> completer, {
    required bool isManual,
  }) async {
    try {
      WebdavSyncResult lastResult;
      do {
        _syncRerunRequested = false;
        lastResult = await _syncOnce(isManual: isManual);
      } while (_syncRerunRequested);
      completer.complete(lastResult);
    } catch (e, s) {
      _logger.severe('Unexpected failure while coalescing syncs', e, s);
      completer.complete(
        WebdavSyncResult(success: false, message: e.toString()),
      );
    } finally {
      _syncInFlight = null;
    }
  }

  Future<WebdavSyncResult> _syncOnce({required bool isManual}) async {
    try {
      if (AuthenticatorService.instance.getAccountMode() ==
          AccountMode.online) {
        throw const WebdavSyncException(
          'WebDAV sync is only available in offline mode',
        );
      }
      if (!isManual && !isEnabled) {
        throw const WebdavSyncException('WebDAV sync is disabled');
      }
      if (!isConfigComplete) {
        throw const WebdavSyncException('WebDAV sync is not configured');
      }
      final webdavPassword = await Configuration.instance.getWebdavPassword();
      if (webdavPassword == null || webdavPassword.isEmpty) {
        throw const WebdavSyncException('WebDAV password is not set');
      }
      final syncPassword =
          await Configuration.instance.getWebdavSyncPassword();
      if (syncPassword == null || syncPassword.isEmpty) {
        throw const WebdavSyncException('Sync password is not set');
      }
      final server = serverUrl;
      if (!server.startsWith('http://') && !server.startsWith('https://')) {
        throw const WebdavSyncException(
          'Server URL must start with http:// or https://',
        );
      }

      final snapshot =
          await AuthenticatorService.instance.getOfflineSyncSnapshot();
      final localVault = await _buildLocalVault(snapshot);
      final fileUrl = _fileUrl(server, remotePath);
      final headers = _authHeaders(username, webdavPassword);

      final remoteBytes = await _downloadVault(fileUrl, headers);
      WebdavVault remoteVault;
      var remoteExisted = false;
      if (remoteBytes == null) {
        remoteVault = WebdavVault.empty();
      } else {
        remoteExisted = true;
        remoteVault = await _decryptVault(remoteBytes, syncPassword);
      }

      final merged = WebdavVault.merge(localVault, remoteVault);
      final outcome = await _applyMerged(
        localSnapshot: snapshot,
        localVault: localVault,
        merged: merged,
      );

      final mergedBytes = await _encryptVault(merged, syncPassword);
      await _uploadVault(fileUrl, headers, mergedBytes, server);

      final pushed = _countPushed(merged, remoteVault, remoteExisted);
      final message = _describeOutcome(outcome, pushed, remoteExisted);
      await _recordLastSync(message);
      return WebdavSyncResult(
        success: true,
        message: message,
        remoteApplied: outcome.remoteApplied,
        localPushed: pushed,
        iconErrors: outcome.iconErrors,
      );
    } on WebdavSyncException catch (e) {
      await _recordLastSync(e.message);
      return WebdavSyncResult(success: false, message: e.message);
    } on OfflineSnapshotException catch (e) {
      final message =
          '${e.undecryptableCount} stored codes could not be decrypted; sync aborted';
      await _recordLastSync(message);
      return WebdavSyncResult(success: false, message: message);
    } catch (e, s) {
      _logger.severe('WebDAV sync failed', e, s);
      final message = e.toString();
      await _recordLastSync(message);
      return WebdavSyncResult(success: false, message: message);
    }
  }

  Future<WebdavVault> _buildLocalVault(OfflineSyncSnapshot snapshot) async {
    final referenced = <String>{};
    for (final record in snapshot.records) {
      final iconId = WebdavVault.iconImageIdOf(record.data);
      if (iconId != null && iconId.isNotEmpty) {
        referenced.add(iconId);
      }
    }
    final icons = <String, String>{};
    for (final id in referenced) {
      final bytes = CodeIconStore.instance.bytesFor(id);
      if (bytes != null) {
        icons[id] = base64Encode(bytes);
      }
    }
    return WebdavVault(
      entities: snapshot.records,
      tombstones: snapshot.tombstones.entries
          .map((e) => WebdavTombstone(syncId: e.key, deletedAt: e.value))
          .toList(),
      icons: icons,
    );
  }

  Future<_ApplyOutcome> _applyMerged({
    required OfflineSyncSnapshot localSnapshot,
    required WebdavVault localVault,
    required WebdavVault merged,
  }) async {
    final localById = {for (final r in localSnapshot.records) r.syncId: r};
    final mergedById = {for (final r in merged.entities) r.syncId: r};

    final upserts = <WebdavVaultRecord>[];
    for (final record in merged.entities) {
      final local = localById[record.syncId];
      if (local == null ||
          local.updatedAt != record.updatedAt ||
          local.data != record.data) {
        upserts.add(record);
      }
    }
    final deletes = localById.keys
        .where((syncId) => !mergedById.containsKey(syncId))
        .toList();
    final tombstones = {
      for (final t in merged.tombstones) t.syncId: t.deletedAt,
    };

    var iconErrors = 0;
    for (final entry in merged.icons.entries) {
      try {
        final bytes = base64Decode(entry.value);
        final existing = CodeIconStore.instance.bytesFor(entry.key);
        if (existing == null || !_bytesEqual(existing, bytes)) {
          await CodeIconStore.instance.saveIconBytes(entry.key, bytes);
        }
      } catch (e, s) {
        iconErrors++;
        _logger.warning('Skipping undecodable icon ${entry.key}', e, s);
      }
    }

    await AuthenticatorService.instance.applyOfflineSyncSnapshot(
      upserts: upserts,
      deleteSyncIds: deletes,
      tombstones: tombstones,
    );

    final referenced = <String>{};
    for (final record in merged.entities) {
      final iconId = WebdavVault.iconImageIdOf(record.data);
      if (iconId != null && iconId.isNotEmpty) {
        referenced.add(iconId);
      }
    }
    await CodeIconStore.instance.prune(referenced);

    return _ApplyOutcome(
      remoteApplied: upserts.length + deletes.length,
      iconErrors: iconErrors,
    );
  }

  int _countPushed(
    WebdavVault merged,
    WebdavVault remote,
    bool remoteExisted,
  ) {
    if (!remoteExisted) return merged.entities.length;
    final remoteById = {for (final r in remote.entities) r.syncId: r};
    var pushed = 0;
    for (final record in merged.entities) {
      final remoteRecord = remoteById[record.syncId];
      if (remoteRecord == null || remoteRecord.updatedAt < record.updatedAt) {
        pushed++;
      }
    }
    return pushed;
  }

  String _describeOutcome(
    _ApplyOutcome outcome,
    int pushed,
    bool remoteExisted,
  ) {
    final parts = <String>[];
    if (!remoteExisted) {
      parts.add('uploaded $pushed codes (first sync)');
    } else {
      if (outcome.remoteApplied > 0) {
        parts.add('applied ${outcome.remoteApplied} remote changes');
      }
      if (pushed > 0) {
        parts.add('uploaded $pushed local changes');
      }
      if (parts.isEmpty) {
        parts.add('already in sync');
      }
    }
    if (outcome.iconErrors > 0) {
      parts.add('${outcome.iconErrors} icons skipped (undecodable)');
    }
    return parts.join('; ');
  }

  Future<void> _recordLastSync(String message) async {
    await _prefs.setInt(
      _keyLastSyncAt,
      DateTime.now().millisecondsSinceEpoch,
    );
    await _prefs.setString(_keyLastMessage, message);
  }

  Future<WebdavTestResult> testConnection() async {
    try {
      if (!isConfigComplete) {
        return const WebdavTestResult(
          reachable: false,
          fileExists: false,
          message: 'WebDAV sync is not configured',
        );
      }
      final webdavPassword = await Configuration.instance.getWebdavPassword();
      if (webdavPassword == null || webdavPassword.isEmpty) {
        return const WebdavTestResult(
          reachable: false,
          fileExists: false,
          message: 'WebDAV password is not set',
        );
      }
      final server = serverUrl;
      if (!server.startsWith('http://') && !server.startsWith('https://')) {
        return const WebdavTestResult(
          reachable: false,
          fileExists: false,
          message: 'Server URL must start with http:// or https://',
        );
      }
      final bytes = await _downloadVault(
        _fileUrl(server, remotePath),
        _authHeaders(username, webdavPassword),
      );
      return WebdavTestResult(
        reachable: true,
        fileExists: bytes != null,
        message: bytes != null
            ? 'Connected; a sync file already exists on the server'
            : 'Connected; no sync file on the server yet',
      );
    } on WebdavSyncException catch (e) {
      return WebdavTestResult(
        reachable: false,
        fileExists: false,
        message: e.message,
      );
    } catch (e, s) {
      _logger.warning('WebDAV connection test failed', e, s);
      return WebdavTestResult(
        reachable: false,
        fileExists: false,
        message: e.toString(),
      );
    }
  }

  String _fileUrl(String server, String path) {
    final base = server.endsWith('/')
        ? server.substring(0, server.length - 1)
        : server;
    final clean = path.startsWith('/') ? path.substring(1) : path;
    return '$base/$clean';
  }

  Map<String, String> _authHeaders(String user, String password) {
    final credentials = base64Encode(utf8.encode('$user:$password'));
    return {'Authorization': 'Basic $credentials'};
  }

  /// Download the vault file. Returns null when the server has no file
  /// (404, or 409 when a parent collection does not exist yet). Never
  /// requests the collection root itself: some servers answer that with
  /// 403 regardless of credentials.
  Future<Uint8List?> _downloadVault(
    String fileUrl,
    Map<String, String> headers,
  ) async {
    final response = await _dio.get(
      fileUrl,
      options: Options(headers: headers, responseType: ResponseType.bytes),
    );
    final status = response.statusCode ?? 0;
    if (status == 200) {
      final data = response.data;
      if (data is List<int>) {
        return Uint8List.fromList(data);
      }
      return Uint8List.fromList(utf8.encode(data.toString()));
    }
    if (status == 404 || status == 409) {
      return null;
    }
    if (status == 401) {
      throw const WebdavSyncException(
        'WebDAV authentication failed (401). Check the username and password.',
      );
    }
    throw WebdavSyncException(
      'WebDAV server returned $status while downloading the sync file',
    );
  }

  Future<void> _uploadVault(
    String fileUrl,
    Map<String, String> headers,
    Uint8List bytes,
    String server,
  ) async {
    final response = await _put(fileUrl, headers, bytes);
    if (response == null) return;
    if (response == 409) {
      await _createParentCollections(server, headers);
      final retry = await _put(fileUrl, headers, bytes);
      if (retry == null) return;
      throw WebdavSyncException(
        'WebDAV server returned $retry while uploading the sync file',
      );
    }
    if (response == 401) {
      throw const WebdavSyncException(
        'WebDAV authentication failed (401). Check the username and password.',
      );
    }
    throw WebdavSyncException(
      'WebDAV server returned $response while uploading the sync file',
    );
  }

  /// PUT the vault. Returns null on success, otherwise the status code.
  Future<int?> _put(
    String fileUrl,
    Map<String, String> headers,
    Uint8List bytes,
  ) async {
    final response = await _dio.put(
      fileUrl,
      data: bytes,
      options: Options(
        headers: {...headers, 'Content-Type': 'application/json'},
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 200 || status == 201 || status == 204) {
      return null;
    }
    return status;
  }

  /// Create each missing parent collection of the remote path, top-down.
  /// 405 (already exists) is fine.
  Future<void> _createParentCollections(
    String server,
    Map<String, String> headers,
  ) async {
    final segments = remotePath.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length <= 1) return;
    final base = server.endsWith('/')
        ? server.substring(0, server.length - 1)
        : server;
    var prefix = base;
    for (var i = 0; i < segments.length - 1; i++) {
      prefix = '$prefix/${segments[i]}';
      final response = await _dio.fetch(
        RequestOptions(path: prefix, method: 'MKCOL', headers: headers),
      );
      final status = response.statusCode ?? 0;
      if (status != 201 && status != 405) {
        throw WebdavSyncException(
          'WebDAV server returned $status while creating $prefix',
        );
      }
    }
  }

  Future<Uint8List> _encryptVault(WebdavVault vault, String password) async {
    final kekSalt = CryptoUtil.getSaltToDeriveKey();
    final derivedKeyResult = await CryptoUtil.deriveSensitiveKey(
      utf8.encode(password),
      kekSalt,
    );
    final encResult = await CryptoUtil.encryptData(
      utf8.encode(vault.encode()),
      derivedKeyResult.key,
    );
    final data = EnteAuthExport(
      version: 1,
      encryptedData: CryptoUtil.bin2base64(encResult.encryptedData!),
      encryptionNonce: CryptoUtil.bin2base64(encResult.header!),
      kdfParams: KDFParams(
        memLimit: derivedKeyResult.memLimit,
        opsLimit: derivedKeyResult.opsLimit,
        salt: CryptoUtil.bin2base64(kekSalt),
      ),
    );
    return Uint8List.fromList(utf8.encode(jsonEncode(data.toJson())));
  }

  Future<WebdavVault> _decryptVault(
    Uint8List bytes,
    String password,
  ) async {
    late final EnteAuthExport envelope;
    try {
      envelope = EnteAuthExport.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
    } catch (e, s) {
      _logger.warning('Remote sync file is not a valid vault envelope', e, s);
      throw const WebdavSyncException(
        'The sync file on the server is not a valid vault',
      );
    }
    final derivedKey = await CryptoUtil.deriveKey(
      utf8.encode(password),
      CryptoUtil.base642bin(envelope.kdfParams.salt),
      envelope.kdfParams.memLimit,
      envelope.kdfParams.opsLimit,
    );
    late final Uint8List decrypted;
    try {
      decrypted = await CryptoUtil.decryptData(
        CryptoUtil.base642bin(envelope.encryptedData),
        derivedKey,
        CryptoUtil.base642bin(envelope.encryptionNonce),
      );
    } catch (e, s) {
      _logger.warning('Failed to decrypt remote vault', e, s);
      throw const WebdavSyncException(
        'Could not decrypt the sync file. Check the sync password.',
        wrongPassword: true,
      );
    }
    try {
      return WebdavVault.decode(utf8.decode(decrypted));
    } catch (e, s) {
      _logger.warning('Decrypted vault has an unexpected format', e, s);
      throw const WebdavSyncException(
        'The sync file on the server has an unexpected format',
      );
    }
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _ApplyOutcome {
  final int remoteApplied;
  final int iconErrors;

  const _ApplyOutcome({required this.remoteApplied, required this.iconErrors});
}
