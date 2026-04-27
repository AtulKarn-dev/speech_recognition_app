import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:speech_recognition_app/speech/speech_session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persists speech sessions into sqflite', () async {
    sqfliteFfiInit();
    final databaseFactory = databaseFactoryFfi;
    final tempDirectory = await Directory.systemTemp.createTemp(
      'speech-session-store-test',
    );
    addTearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final store = SqfliteSpeechSessionStore(
      sqliteDatabaseFactory: databaseFactory,
      getDatabasesPathCallback: () async => tempDirectory.path,
    );

    await store.saveSession(
      transcript: 'first sqlite entry',
      languageLabel: 'English',
      localeId: 'en-US',
      createdAt: DateTime(2026, 4, 27, 9, 30),
    );
    await store.saveSession(
      transcript: 'second sqlite entry',
      languageLabel: 'Nepali',
      localeId: 'ne-NP',
      createdAt: DateTime(2026, 4, 27, 9, 31),
    );
    await store.close();

    final database = await databaseFactory.openDatabase(
      path.join(tempDirectory.path, 'speech_sessions.db'),
      options: OpenDatabaseOptions(readOnly: true),
    );
    addTearDown(database.close);

    final rows = await database.query('speech_sessions', orderBy: 'id ASC');
    expect(rows, hasLength(2));
    expect(rows[0]['transcript'], 'first sqlite entry');
    expect(rows[0]['languageLabel'], 'English');
    expect(rows[1]['transcript'], 'second sqlite entry');
    expect(rows[1]['localeId'], 'ne-NP');
  });
}
