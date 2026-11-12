import 'dart:async';
import 'dart:io';

import 'package:ente_auth/models/authenticator/auth_entity.dart';
import 'package:ente_auth/models/authenticator/local_auth_entity.dart';
import 'package:ente_auth/utils/directory_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

class OfflineAuthenticatorDB {
  static const _databaseName = "ente.offline_authenticator.db";
  // v2 (enteauth slice): syncId column for WebDAV sync identity plus the
  // deleted_entities tombstone table.
  static const _databaseVersion = 2;

  static const entityTable = 'entities';
  static const tombstoneTable = 'deleted_entities';

  OfflineAuthenticatorDB._privateConstructor();
  static final OfflineAuthenticatorDB instance =
      OfflineAuthenticatorDB._privateConstructor();

  static Future<Database>? _dbFuture;

  Future<Database> get database async {
    _dbFuture ??= _initDatabase();
    return _dbFuture!;
  }

  Future<Database> _initDatabase() async {
    if (Platform.isWindows || Platform.isLinux) {
      var databaseFactory = databaseFactoryFfi;
      return await databaseFactory.openDatabase(
        await DirectoryUtils.getDatabasePath(_databaseName),
        options: OpenDatabaseOptions(
          version: _databaseVersion,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    }
    final Directory documentsDirectory = Platform.isMacOS
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();
    final String path = join(documentsDirectory.path, _databaseName);
    debugPrint(path);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onCreate(Database db, int version) async {
    await db.execute('''
                CREATE TABLE $entityTable (
                  _generatedID INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  id TEXT,
                  encryptedData TEXT NOT NULL,
                  header TEXT NOT NULL,
                  createdAt INTEGER NOT NULL,
                  updatedAt INTEGER NOT NULL,
                  shouldSync INTEGER DEFAULT 0,
                  syncId TEXT,
                  UNIQUE(id)
                );
      ''');
    await db.execute(
      'CREATE UNIQUE INDEX idx_entities_syncId ON $entityTable(syncId);',
    );
    await db.execute('''
                CREATE TABLE $tombstoneTable (
                  syncId TEXT PRIMARY KEY NOT NULL,
                  deletedAt INTEGER NOT NULL
                );
      ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE $entityTable ADD COLUMN syncId TEXT;');
      // Backfill a stable sync id for every pre-existing row.
      final rows = await db.query(entityTable, columns: ['_generatedID']);
      final batch = db.batch();
      for (final row in rows) {
        batch.update(
          entityTable,
          {'syncId': const Uuid().v4()},
          where: '_generatedID = ?',
          whereArgs: [row['_generatedID']],
        );
      }
      await batch.commit(noResult: true);
      await db.execute(
        'CREATE UNIQUE INDEX idx_entities_syncId ON $entityTable(syncId);',
      );
      await db.execute('''
                CREATE TABLE $tombstoneTable (
                  syncId TEXT PRIMARY KEY NOT NULL,
                  deletedAt INTEGER NOT NULL
                );
      ''');
    }
  }

  Future<int> insert(String encData, String header, {String? syncId}) async {
    final db = await instance.database;
    final int timeInMicroSeconds = DateTime.now().microsecondsSinceEpoch;
    final insertedID = await db.insert(entityTable, {
      "encryptedData": encData,
      "header": header,
      "shouldSync": 1,
      "createdAt": timeInMicroSeconds,
      "updatedAt": timeInMicroSeconds,
      "syncId": syncId ?? const Uuid().v4(),
    });
    return insertedID;
  }

  Future<int> updateEntry(
    int generatedID,
    String encData,
    String header,
  ) async {
    final db = await instance.database;
    final int timeInMicroSeconds = DateTime.now().microsecondsSinceEpoch;
    int affectedRows = await db.update(
      entityTable,
      {
        "encryptedData": encData,
        "header": header,
        "shouldSync": 1,
        "updatedAt": timeInMicroSeconds,
      },
      where: '_generatedID = ?',
      whereArgs: [generatedID],
    );
    return affectedRows;
  }

  Future<void> insertOrReplace(List<AuthEntity> authEntities) async {
    final db = await instance.database;
    final batch = db.batch();
    for (AuthEntity authEntity in authEntities) {
      final insertRow = authEntity.toMap();
      insertRow.remove('isDeleted');
      insertRow.putIfAbsent('shouldSync', () => 0);
      insertRow.putIfAbsent('syncId', () => const Uuid().v4());
      batch.insert(
        entityTable,
        insertRow,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateLocalEntity(LocalAuthEntity localAuthEntity) async {
    final db = await instance.database;
    await db.update(
      entityTable,
      localAuthEntity.toMap(includeSyncId: true),
      where: '_generatedID = ?',
      whereArgs: [localAuthEntity.generatedID],
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<LocalAuthEntity?> getEntryByID(int genID) async {
    final db = await instance.database;
    final rows = await db.query(
      entityTable,
      where: '_generatedID = ?',
      whereArgs: [genID],
    );
    final listOfAuthEntities = _convertRows(rows);
    if (listOfAuthEntities.isEmpty) {
      return null;
    } else {
      return listOfAuthEntities.first;
    }
  }

  Future<List<LocalAuthEntity>> getAll() async {
    final db = await instance.database;
    final rows = await db.rawQuery("SELECT * from $entityTable");
    return _convertRows(rows);
  }

  Future<void> deleteByIDs({List<int>? generatedIDs, List<String>? ids}) async {
    final db = await instance.database;
    final batch = db.batch();
    const whereGenID = '_generatedID = ?';
    const whereID = 'id = ?';
    if (generatedIDs != null) {
      for (int genId in generatedIDs) {
        batch.delete(entityTable, where: whereGenID, whereArgs: [genId]);
      }
    }
    if (ids != null) {
      for (String id in ids) {
        batch.delete(entityTable, where: whereID, whereArgs: [id]);
      }
    }
    final _ = await batch.commit();
    debugPrint("Done");
  }

  Future<void> clearTable() async {
    final db = await instance.database;
    await db.delete(entityTable);
    await db.delete(tombstoneTable);
  }

  Future<LocalAuthEntity?> getBySyncId(String syncId) async {
    final db = await instance.database;
    final rows = await db.query(
      entityTable,
      where: 'syncId = ?',
      whereArgs: [syncId],
    );
    final listOfAuthEntities = _convertRows(rows);
    if (listOfAuthEntities.isEmpty) {
      return null;
    } else {
      return listOfAuthEntities.first;
    }
  }

  /// Insert or update an entity by its stable sync id, preserving the
  /// local generated id of an existing row. Used to apply merged WebDAV
  /// sync state. Returns the generated id of the affected row.
  Future<int> upsertBySyncId({
    required String syncId,
    required String encData,
    required String header,
    required int createdAt,
    required int updatedAt,
  }) async {
    final existing = await getBySyncId(syncId);
    final db = await instance.database;
    if (existing != null) {
      await db.update(
        entityTable,
        {
          "encryptedData": encData,
          "header": header,
          "updatedAt": updatedAt,
          "shouldSync": 0,
        },
        where: '_generatedID = ?',
        whereArgs: [existing.generatedID],
      );
      return existing.generatedID;
    }
    return await db.insert(entityTable, {
      "encryptedData": encData,
      "header": header,
      "shouldSync": 0,
      "createdAt": createdAt,
      "updatedAt": updatedAt,
      "syncId": syncId,
    });
  }

  Future<void> deleteBySyncIds(List<String> syncIds) async {
    if (syncIds.isEmpty) return;
    final db = await instance.database;
    final batch = db.batch();
    for (final syncId in syncIds) {
      batch.delete(entityTable, where: 'syncId = ?', whereArgs: [syncId]);
    }
    await batch.commit(noResult: true);
  }

  /// Tombstones keyed by sync id, valued by deletion time (microseconds).
  Future<Map<String, int>> getTombstones() async {
    final db = await instance.database;
    final rows = await db.query(tombstoneTable);
    final result = <String, int>{};
    for (final row in rows) {
      result[row['syncId'] as String] = row['deletedAt'] as int;
    }
    return result;
  }

  /// Upsert tombstones, keeping the latest deletion time per sync id.
  Future<void> putTombstones(Map<String, int> tombstones) async {
    if (tombstones.isEmpty) return;
    final existing = await getTombstones();
    final db = await instance.database;
    final batch = db.batch();
    for (final entry in tombstones.entries) {
      final known = existing[entry.key];
      if (known == null) {
        batch.insert(tombstoneTable, {
          'syncId': entry.key,
          'deletedAt': entry.value,
        });
      } else if (entry.value > known) {
        batch.update(
          tombstoneTable,
          {'deletedAt': entry.value},
          where: 'syncId = ?',
          whereArgs: [entry.key],
        );
      }
    }
    await batch.commit(noResult: true);
  }

  List<LocalAuthEntity> _convertRows(List<Map<String, dynamic>> rows) {
    final keys = <LocalAuthEntity>[];
    for (final row in rows) {
      keys.add(LocalAuthEntity.fromMap(row));
    }
    return keys;
  }
}
