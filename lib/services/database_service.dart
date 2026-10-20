import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/app_settings.dart';
import '../models/screenshot_item.dart';

class DatabaseService {
  Database? _database;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) {
      return existing;
    }

    final opened = await _openDatabase();
    _database = opened;
    return opened;
  }

  Future<Database> _openDatabase() async {
    sqfliteFfiInit();

    final supportDirectory = await getApplicationSupportDirectory();
    final databaseDirectory = Directory(
      p.join(supportDirectory.path, 'SmartScreenshotManager', 'database'),
    );
    await databaseDirectory.create(recursive: true);

    final databasePath = p.join(databaseDirectory.path, 'screenshots.db');

    return databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE screenshots (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              file_path TEXT NOT NULL UNIQUE,
              file_name TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              ocr_text TEXT NOT NULL DEFAULT '',
              search_text TEXT NOT NULL DEFAULT '',
              favorite INTEGER NOT NULL DEFAULT 0
            )
          ''');

          await db.execute(
            'CREATE INDEX idx_screenshots_created_at '
            'ON screenshots(created_at DESC)',
          );
          await db.execute(
            'CREATE INDEX idx_screenshots_favorite '
            'ON screenshots(favorite)',
          );
          await _createSettingsTable(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          // v1 -> v2: таблица настроек. Старые снимки остаются как были.
          if (oldVersion < 2) {
            await _createSettingsTable(db);
          }
        },
      ),
    );
  }

  static Future<void> _createSettingsTable(Database db) {
    return db.execute(
      'CREATE TABLE IF NOT EXISTS settings ('
      'key TEXT PRIMARY KEY, '
      'value TEXT NOT NULL'
      ')',
    );
  }

  Future<AppSettings> loadSettings() async {
    final db = await database;
    final rows = await db.query('settings');
    final map = <String, String>{};
    for (final row in rows) {
      map[row['key'] as String] = (row['value'] as String?) ?? '';
    }
    return AppSettings(
      autoCopy: (map['auto_copy'] ?? '1') == '1',
      autoOcr: (map['auto_ocr'] ?? '1') == '1',
      delaySeconds: int.tryParse(map['delay_seconds'] ?? '') ?? 0,
    );
  }

  Future<void> saveSettings(AppSettings settings) async {
    final db = await database;
    final batch = db.batch();

    void put(String key, String value) {
      batch.insert(
        'settings',
        <String, Object?>{'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    put('auto_copy', settings.autoCopy ? '1' : '0');
    put('auto_ocr', settings.autoOcr ? '1' : '0');
    put('delay_seconds', settings.delaySeconds.toString());
    await batch.commit(noResult: true);
  }

  Future<int> insertScreenshot(ScreenshotItem item) async {
    final db = await database;
    return db.insert('screenshots', item.toMap());
  }

  Future<List<ScreenshotItem>> getScreenshots({
    String search = '',
    bool favoritesOnly = false,
  }) async {
    final db = await database;

    // Несколько слов ищутся независимо (И): «счёт 2024» найдёт скриншот,
    // где есть и «счёт», и «2024», в любом порядке.
    final terms = search
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();

    final clauses = <String>[];
    final whereArgs = <Object?>[];
    if (favoritesOnly) {
      clauses.add('favorite = 1');
    }
    for (final term in terms) {
      clauses.add("search_text LIKE ? ESCAPE '\\'");
      whereArgs.add('%${_escapeLike(term)}%');
    }

    final rows = await db.query(
      'screenshots',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'created_at DESC',
    );

    return rows.map(ScreenshotItem.fromMap).toList(growable: false);
  }

  static String _escapeLike(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
  }

  Future<void> setFavorite(int id, bool favorite) async {
    final db = await database;
    await db.update(
      'screenshots',
      <String, Object?>{'favorite': favorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> updateOcr({
    required int id,
    required String fileName,
    required String ocrText,
  }) async {
    final db = await database;
    final searchText = '$fileName\n$ocrText'.toLowerCase();

    await db.update(
      'screenshots',
      <String, Object?>{
        'ocr_text': ocrText,
        'search_text': searchText,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> deleteScreenshot(int id) async {
    final db = await database;
    await db.delete(
      'screenshots',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
