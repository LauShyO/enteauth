// Local addition (enteauth slice): on-device store for gallery-picked code
// icons. Images are downscaled to at most 512px on the long side, stored as
// PNG files under the app support directory, and mirrored in memory so icon
// widgets can render them synchronously. Syncing the bytes across devices
// is the WebDAV sync service's job; this store only owns local files.
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class CodeIconStore {
  CodeIconStore._privateConstructor();

  static final CodeIconStore instance = CodeIconStore._privateConstructor();

  final _logger = Logger('CodeIconStore');
  final Map<String, Uint8List> _cache = {};

  static const int maxDimension = 512;
  static const int maxSourceBytes = 10 * 1024 * 1024;

  late Directory _dir;
  bool _initialized = false;

  static String newIconId() => 'img_${const Uuid().v4()}';

  Future<void> init() async {
    if (_initialized) return;
    final supportDir = await getApplicationSupportDirectory();
    _dir = Directory(p.join(supportDir.path, 'custom_code_icons'));
    await _dir.create(recursive: true);
    await reloadCache();
    _initialized = true;
  }

  Future<void> reloadCache() async {
    _cache.clear();
    await for (final entity in _dir.list()) {
      if (entity is! File || !entity.path.endsWith('.png')) continue;
      final id = p.basenameWithoutExtension(entity.path);
      try {
        _cache[id] = await entity.readAsBytes();
      } catch (e, s) {
        _logger.warning('Failed to read cached icon $id', e, s);
      }
    }
  }

  Uint8List? bytesFor(String iconImageId) => _cache[iconImageId];

  bool hasIcon(String iconImageId) => _cache.containsKey(iconImageId);

  File _fileFor(String iconImageId) => File(p.join(_dir.path, '$iconImageId.png'));

  /// Downscale picked image bytes and store them under [iconImageId]
  /// (or a fresh id when none is given). Returns the id the image was
  /// stored under. Throws [ArgumentError] for undecodable input.
  Future<String> savePickedImage(
    Uint8List rawBytes, {
    String? iconImageId,
  }) async {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      throw ArgumentError('Picked file is not a decodable image');
    }
    final id = iconImageId ?? newIconId();
    final resized = _fitWithin(decoded, maxDimension);
    final png = Uint8List.fromList(img.encodePng(resized));
    await _fileFor(id).writeAsBytes(png, flush: true);
    _cache[id] = png;
    return id;
  }

  /// Store icon bytes received from sync (already PNG, already sized).
  Future<void> saveIconBytes(String iconImageId, Uint8List pngBytes) async {
    await _fileFor(iconImageId).writeAsBytes(pngBytes, flush: true);
    _cache[iconImageId] = pngBytes;
  }

  Future<void> deleteIcon(String iconImageId) async {
    _cache.remove(iconImageId);
    try {
      await _fileFor(iconImageId).delete();
    } catch (_) {
      // Missing file is fine; the reference is gone either way.
    }
  }

  /// Delete every stored icon whose id is not in [keepIds].
  Future<void> prune(Set<String> keepIds) async {
    final stale = _cache.keys.where((id) => !keepIds.contains(id)).toList();
    for (final id in stale) {
      await deleteIcon(id);
    }
    // Also sweep files that never made it into the cache.
    await for (final entity in _dir.list()) {
      if (entity is! File || !entity.path.endsWith('.png')) continue;
      final id = p.basenameWithoutExtension(entity.path);
      if (!keepIds.contains(id)) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  img.Image _fitWithin(img.Image source, int maxSide) {
    if (source.width <= maxSide && source.height <= maxSide) {
      return source;
    }
    final scale = maxSide / (source.width > source.height ? source.width : source.height);
    return img.copyResize(
      source,
      width: (source.width * scale).round(),
      height: (source.height * scale).round(),
    );
  }
}
