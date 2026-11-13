import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/events/codes_updated_event.dart';
import 'package:ente_auth/models/authenticator/entity_result.dart';
import 'package:ente_auth/models/authenticator/local_auth_entity.dart';
import 'package:ente_auth/models/webdav_vault.dart';
import 'package:ente_auth/store/authenticator_db.dart';
import 'package:ente_auth/store/offline_authenticator_db.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_events/event_bus.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

enum AccountMode { online, offline }

extension on AccountMode {
  bool get isOnline => this == AccountMode.online;
  bool get isOffline => this == AccountMode.offline;
}

class AuthenticatorService {
  final _logger = Logger((AuthenticatorService).toString());
  final _config = Configuration.instance;
  late AuthenticatorDB _db;
  late OfflineAuthenticatorDB _offlineDb;

  AuthenticatorService._privateConstructor();

  static final AuthenticatorService instance =
      AuthenticatorService._privateConstructor();

  // Local change (enteauth slice): no Ente account. The account mode is
  // always offline; syncing goes through WebDAV instead.
  AccountMode getAccountMode() {
    return AccountMode.offline;
  }

  Future<void> init() async {
    _db = AuthenticatorDB.instance;
    _offlineDb = OfflineAuthenticatorDB.instance;
  }

  Future<List<EntityResult>> getEntities(AccountMode mode) async {
    final List<LocalAuthEntity> result = mode.isOnline
        ? await _db.getAll()
        : await _offlineDb.getAll();
    final List<EntityResult> entities = [];
    if (result.isEmpty) {
      return entities;
    }
    final key = await getOrCreateAuthDataKey(mode);
    for (LocalAuthEntity e in result) {
      try {
        final decryptedValue = await CryptoUtil.decryptData(
          CryptoUtil.base642bin(e.encryptedData),
          key,
          CryptoUtil.base642bin(e.header),
        );
        final hasSynced = !(e.id == null || e.shouldSync);
        entities.add(
          EntityResult(
            e.generatedID,
            utf8.decode(decryptedValue),
            hasSynced,
            e.createdAt,
          ),
        );
      } catch (e, s) {
        _logger.severe(e, s);
      }
    }
    return entities;
  }

  Future<int> addEntry(
    String plainText,
    bool shouldSync,
    AccountMode accountMode,
  ) async {
    var key = await getOrCreateAuthDataKey(accountMode);
    final encryptedKeyData = await CryptoUtil.encryptData(
      utf8.encode(plainText),
      key,
    );
    String encryptedData = CryptoUtil.bin2base64(
      encryptedKeyData.encryptedData!,
    );
    String header = CryptoUtil.bin2base64(encryptedKeyData.header!);
    final insertedID = accountMode.isOnline
        ? await _db.insert(encryptedData, header)
        : await _offlineDb.insert(encryptedData, header);
    if (shouldSync) {
      unawaited(onlineSync());
    }
    return insertedID;
  }

  Future<void> updateEntry(
    int generatedID,
    String plainText,
    bool shouldSync,
    AccountMode accountMode,
  ) async {
    var key = await getOrCreateAuthDataKey(accountMode);
    final encryptedKeyData = await CryptoUtil.encryptData(
      utf8.encode(plainText),
      key,
    );
    String encryptedData = CryptoUtil.bin2base64(
      encryptedKeyData.encryptedData!,
    );
    String header = CryptoUtil.bin2base64(encryptedKeyData.header!);
    final int affectedRows = accountMode.isOnline
        ? await _db.updateEntry(generatedID, encryptedData, header)
        : await _offlineDb.updateEntry(generatedID, encryptedData, header);
    assert(
      affectedRows == 1,
      "updateEntry should have updated exactly one row",
    );
    if (shouldSync) {
      unawaited(onlineSync());
    }
  }

  Future<void> deleteEntry(int genID, AccountMode accountMode) async {
    LocalAuthEntity? result = accountMode.isOnline
        ? await _db.getEntryByID(genID)
        : await _offlineDb.getEntryByID(genID);
    if (result == null) {
      _logger.info("No entry found for given id");
      return;
    }
    if (accountMode.isOnline) {
      await _db.deleteByIDs(generatedIDs: [genID]);
    } else {
      // Local addition (enteauth slice): record a deletion tombstone so
      // WebDAV sync can propagate the deletion to other devices.
      if (result.syncId != null) {
        await _offlineDb.putTombstones({
          result.syncId!: DateTime.now().microsecondsSinceEpoch,
        });
      }
      await _offlineDb.deleteByIDs(generatedIDs: [genID]);
    }
  }

  /// Decrypted snapshot of the offline database for WebDAV sync. Throws
  /// [OfflineSnapshotException] when any stored entity cannot be decrypted,
  /// so a sync never silently drops codes it failed to read.
  Future<OfflineSyncSnapshot> getOfflineSyncSnapshot() async {
    final rows = await _offlineDb.getAll();
    final key = await getOrCreateAuthDataKey(AccountMode.offline);
    final records = <WebdavVaultRecord>[];
    var failures = 0;
    for (final row in rows) {
      try {
        final decrypted = await CryptoUtil.decryptData(
          CryptoUtil.base642bin(row.encryptedData),
          key,
          CryptoUtil.base642bin(row.header),
        );
        var syncId = row.syncId;
        if (syncId == null) {
          // Rows predating the syncId column get a stable id persisted
          // before the snapshot is built, so the id never changes.
          syncId = const Uuid().v4();
          await _offlineDb.updateLocalEntity(row.copyWith(syncId: syncId));
        }
        records.add(
          WebdavVaultRecord(
            syncId: syncId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            data: utf8.decode(decrypted),
          ),
        );
      } catch (e, s) {
        failures++;
        _logger.severe('Failed to decrypt offline entity ${row.generatedID}', e, s);
      }
    }
    if (failures > 0) {
      throw OfflineSnapshotException(failures);
    }
    final tombstones = await _offlineDb.getTombstones();
    return OfflineSyncSnapshot(records: records, tombstones: tombstones);
  }

  /// Apply merged WebDAV sync state to the offline database: upsert the
  /// winning records (re-encrypted with the local offline key), delete
  /// tombstoned rows, and store the merged tombstones.
  Future<void> applyOfflineSyncSnapshot({
    required List<WebdavVaultRecord> upserts,
    required List<String> deleteSyncIds,
    required Map<String, int> tombstones,
  }) async {
    final key = await getOrCreateAuthDataKey(AccountMode.offline);
    for (final record in upserts) {
      final encrypted = await CryptoUtil.encryptData(
        utf8.encode(record.data),
        key,
      );
      await _offlineDb.upsertBySyncId(
        syncId: record.syncId,
        encData: CryptoUtil.bin2base64(encrypted.encryptedData!),
        header: CryptoUtil.bin2base64(encrypted.header!),
        createdAt: record.createdAt,
        updatedAt: record.updatedAt,
      );
    }
    await _offlineDb.deleteBySyncIds(deleteSyncIds);
    await _offlineDb.putTombstones(tombstones);
    // Only notify when the visible list actually changed. WebdavSyncService
    // listens to this event to schedule an auto-sync, so notifying on a
    // no-change sync schedules another sync forever: the coalesced sync
    // future never completes and the sync button spins forever.
    if (upserts.isNotEmpty || deleteSyncIds.isNotEmpty) {
      Bus.instance.fire(CodesUpdatedEvent());
    }
  }

  // Local change (enteauth slice): Ente server sync is removed. The
  // signature is kept so existing call sites keep compiling; syncing goes
  // through WebDAV instead (see WebdavSyncService).
  Future<bool> onlineSync() async => false;

  Future<Uint8List> getOrCreateAuthDataKey(AccountMode mode) async {
    if (mode.isOffline) {
      return _config.getOfflineSecretKey()!;
    }
    throw StateError('Online mode is not available');
  }
}

/// Decrypted contents of the offline database, ready for WebDAV sync.
class OfflineSyncSnapshot {
  final List<WebdavVaultRecord> records;
  final Map<String, int> tombstones;

  const OfflineSyncSnapshot({required this.records, required this.tombstones});
}

class OfflineSnapshotException implements Exception {
  final int undecryptableCount;

  const OfflineSnapshotException(this.undecryptableCount);

  @override
  String toString() =>
      'OfflineSnapshotException: $undecryptableCount stored codes could not be decrypted';
}
