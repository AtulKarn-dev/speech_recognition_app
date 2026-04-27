import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

class SpeechSessionEntry {
  const SpeechSessionEntry({
    required this.transcript,
    required this.languageLabel,
    required this.localeId,
    required this.createdAt,
  });

  final String transcript;
  final String languageLabel;
  final String localeId;
  final DateTime createdAt;

  Map<String, Object?> toMap() {
    return {
      'transcript': transcript,
      'languageLabel': languageLabel,
      'localeId': localeId,
      'createdAt': createdAt.millisecondsSinceEpoch,
    };
  }
}

abstract class SpeechSessionStore {
  Future<void> saveSession({
    required String transcript,
    required String languageLabel,
    required String localeId,
    DateTime? createdAt,
  });

  Future<void> close();
}

class SqfliteSpeechSessionStore implements SpeechSessionStore {
  SqfliteSpeechSessionStore({
    DatabaseFactory? sqliteDatabaseFactory,
    Future<String> Function()? getDatabasesPathCallback,
  }) : _databaseFactory = sqliteDatabaseFactory ?? databaseFactory,
       _getDatabasesPath = getDatabasesPathCallback ?? getDatabasesPath;

  static const String _databaseName = 'speech_sessions.db';
  static const String _tableName = 'speech_sessions';
  static const int _databaseVersion = 1;

  final DatabaseFactory _databaseFactory;
  final Future<String> Function() _getDatabasesPath;
  Database? _database;

  @override
  Future<void> saveSession({
    required String transcript,
    required String languageLabel,
    required String localeId,
    DateTime? createdAt,
  }) async {
    final database = await _openDatabase();
    final session = SpeechSessionEntry(
      transcript: transcript,
      languageLabel: languageLabel,
      localeId: localeId,
      createdAt: createdAt ?? DateTime.now(),
    );

    await database.insert(_tableName, session.toMap());
  }

  @override
  Future<void> close() async {
    final database = _database;
    _database = null;

    if (database != null && database.isOpen) {
      await database.close();
    }
  }

  Future<Database> _openDatabase() async {
    if (_database?.isOpen == true) {
      return _database!;
    }

    final databasePath = await _getDatabasesPath();
    final fullPath = path.join(databasePath, _databaseName);
    _database = await _databaseFactory.openDatabase(
      fullPath,
      options: OpenDatabaseOptions(version: _databaseVersion),
    );
    await _ensureSchema(_database!);
    return _database!;
  }

  Future<void> _ensureSchema(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $_tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transcript TEXT NOT NULL,
        languageLabel TEXT NOT NULL,
        localeId TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');
  }
}
