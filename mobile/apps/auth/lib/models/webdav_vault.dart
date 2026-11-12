// Local addition (enteauth slice): WebDAV sync vault format and merge.
//
// The vault is a single JSON document, encrypted with a sync-password-derived
// key (same envelope as EnteAuthExport) and stored as one file on the WebDAV
// server. Entity payloads are the verbatim entity plaintexts
// (Code.toOTPAuthUrlFormat output), so display state — including the chosen
// icon — survives a sync round-trip without re-parsing codes.
import 'dart:convert';

class WebdavVaultRecord {
  final String syncId;
  final int createdAt;
  final int updatedAt;
  final String data;

  const WebdavVaultRecord({
    required this.syncId,
    required this.createdAt,
    required this.updatedAt,
    required this.data,
  });

  Map<String, dynamic> toJson() => {
    'syncId': syncId,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'data': data,
  };

  factory WebdavVaultRecord.fromJson(Map<String, dynamic> json) {
    return WebdavVaultRecord(
      syncId: json['syncId'] as String,
      createdAt: json['createdAt'] as int,
      updatedAt: json['updatedAt'] as int,
      data: json['data'] as String,
    );
  }
}

class WebdavTombstone {
  final String syncId;
  final int deletedAt;

  const WebdavTombstone({required this.syncId, required this.deletedAt});

  Map<String, dynamic> toJson() => {'syncId': syncId, 'deletedAt': deletedAt};

  factory WebdavTombstone.fromJson(Map<String, dynamic> json) {
    return WebdavTombstone(
      syncId: json['syncId'] as String,
      deletedAt: json['deletedAt'] as int,
    );
  }
}

class WebdavVault {
  static const String format = 'ente-auth-webdav-v1';

  final List<WebdavVaultRecord> entities;
  final List<WebdavTombstone> tombstones;

  /// Gallery icon image bytes (PNG), base64-encoded, keyed by icon image id.
  final Map<String, String> icons;

  const WebdavVault({
    required this.entities,
    required this.tombstones,
    required this.icons,
  });

  factory WebdavVault.empty() =>
      const WebdavVault(entities: [], tombstones: [], icons: {});

  Map<String, dynamic> toJson() => {
    'format': format,
    'entities': entities.map((e) => e.toJson()).toList(),
    'tombstones': tombstones.map((t) => t.toJson()).toList(),
    'icons': icons,
  };

  String encode() => jsonEncode(toJson());

  factory WebdavVault.decode(String source) {
    final Map<String, dynamic> json = jsonDecode(source);
    if (json['format'] != format) {
      throw const FormatException('Not a WebDAV sync vault');
    }
    final entities = (json['entities'] as List)
        .map((e) => WebdavVaultRecord.fromJson(e as Map<String, dynamic>))
        .toList();
    final tombstones = (json['tombstones'] as List)
        .map((t) => WebdavTombstone.fromJson(t as Map<String, dynamic>))
        .toList();
    final icons = Map<String, String>.from(json['icons'] as Map);
    return WebdavVault(
      entities: entities,
      tombstones: tombstones,
      icons: icons,
    );
  }

  /// Merge two vaults. For each sync id the newer updatedAt wins; a
  /// tombstone whose deletedAt is at or after the entity's updatedAt wins
  /// over the entity. Icons are kept only when referenced by a surviving
  /// entity. The merge is symmetric except for exact updatedAt ties, where
  /// [local] wins.
  static WebdavVault merge(WebdavVault local, WebdavVault remote) {
    final tombstoneById = <String, int>{};
    for (final t in [...local.tombstones, ...remote.tombstones]) {
      final existing = tombstoneById[t.syncId];
      if (existing == null || t.deletedAt > existing) {
        tombstoneById[t.syncId] = t.deletedAt;
      }
    }

    final merged = <String, WebdavVaultRecord>{};
    for (final record in [...remote.entities, ...local.entities]) {
      final deletedAt = tombstoneById[record.syncId];
      if (deletedAt != null && deletedAt >= record.updatedAt) {
        continue;
      }
      final existing = merged[record.syncId];
      if (existing == null || record.updatedAt >= existing.updatedAt) {
        // Remote records are visited first, so on an exact tie the local
        // record (>=) replaces the remote one: local wins ties.
        merged[record.syncId] = record;
      }
    }

    final referencedIcons = <String>{};
    for (final record in merged.values) {
      final iconId = iconImageIdOf(record.data);
      if (iconId != null && iconId.isNotEmpty) {
        referencedIcons.add(iconId);
      }
    }
    final icons = <String, String>{};
    for (final entry in {...remote.icons, ...local.icons}.entries) {
      if (referencedIcons.contains(entry.key)) {
        icons[entry.key] = entry.value;
      }
    }

    return WebdavVault(
      entities: merged.values.toList(),
      tombstones: tombstoneById.entries
          .map((e) => WebdavTombstone(syncId: e.key, deletedAt: e.value))
          .toList(),
      icons: icons,
    );
  }

  /// Extract the gallery icon image id referenced by an entity plaintext
  /// (a JSON-encoded otpauth URL carrying a codeDisplay query parameter).
  /// Returns null when the payload carries no gallery icon reference.
  static String? iconImageIdOf(String entityData) {
    try {
      final decoded = jsonDecode(entityData);
      if (decoded is! String) return null;
      final uri = Uri.tryParse(decoded);
      final displayJson = uri?.queryParameters['codeDisplay'];
      if (displayJson == null) return null;
      final display = jsonDecode(displayJson);
      if (display is! Map) return null;
      final iconImageId = display['iconImageId'];
      if (iconImageId is String && iconImageId.isNotEmpty) {
        return iconImageId;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
