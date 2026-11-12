import 'dart:convert';

import 'package:flutter/material.dart';

@immutable
class LocalAuthEntity {
  final int generatedID;

  // Null for scanned codes that have not reached the server.
  final String? id;
  final String encryptedData;
  final String header;

  // Local timestamps until remote sync completes.
  final int createdAt;
  final int updatedAt;

  // True for local changes awaiting remote sync.
  final bool shouldSync;

  // Stable cross-device identity for WebDAV sync (offline mode only).
  // Null for rows in the online database, which keys on the server id.
  final String? syncId;

  LocalAuthEntity(
    this.generatedID,
    this.id,
    this.encryptedData,
    this.header,
    this.createdAt,
    this.updatedAt,
    this.shouldSync, {
    this.syncId,
  });

  LocalAuthEntity copyWith({
    int? generatedID,
    String? id,
    String? encryptedData,
    String? header,
    int? createdAt,
    int? updatedAt,
    bool? shouldSync,
    String? syncId,
  }) {
    return LocalAuthEntity(
      generatedID ?? this.generatedID,
      id ?? this.id,
      encryptedData ?? this.encryptedData,
      header ?? this.header,
      createdAt ?? this.createdAt,
      updatedAt ?? this.updatedAt,
      shouldSync ?? this.shouldSync,
      syncId: syncId ?? this.syncId,
    );
  }

  Map<String, dynamic> toMap({bool includeSyncId = false}) {
    return {
      '_generatedID': generatedID,
      'id': id,
      'encryptedData': encryptedData,
      'header': header,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'shouldSync': shouldSync ? 1 : 0,
      if (includeSyncId && syncId != null) 'syncId': syncId,
    };
  }

  factory LocalAuthEntity.fromMap(Map<String, dynamic> map) {
    return LocalAuthEntity(
      map['_generatedID']!,
      map['id'],
      map['encryptedData']!,
      map['header']!,
      map['createdAt']!,
      map['updatedAt']!,
      (map['shouldSync']! == 0) ? false : true,
      syncId: map['syncId'] as String?,
    );
  }

  String toJson() => json.encode(toMap());

  factory LocalAuthEntity.fromJson(String source) =>
      LocalAuthEntity.fromMap(json.decode(source));
}
