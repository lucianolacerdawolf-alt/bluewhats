import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'message.dart';

/// Historico local das mensagens.
///
/// O chat e ponto a ponto e sem servidor, entao este banco e a unica copia que
/// existe da conversa: se o app perder, a mensagem sumiu para sempre.
class MessageRepository {
  MessageRepository._(this._db);

  final Database _db;

  static Future<MessageRepository> open() async {
    final path = p.join(await getDatabasesPath(), 'blue_whats.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            mine INTEGER NOT NULL,
            sent_at INTEGER NOT NULL
          )
        ''');
        // A tela sempre carrega ordenando por data; sem o indice isso vira
        // varredura completa conforme a conversa cresce.
        await db.execute('CREATE INDEX idx_messages_sent_at ON messages(sent_at)');
      },
    );
    return MessageRepository._(db);
  }

  /// Mensagens em ordem cronologica.
  Future<List<Message>> loadAll() async {
    final rows = await _db.query('messages', orderBy: 'sent_at ASC, id ASC');
    return rows.map(Message.fromRow).toList();
  }

  /// Grava e devolve a mensagem ja com o `id` atribuido pelo banco.
  Future<Message> save(Message message) async {
    final id = await _db.insert('messages', message.toRow());
    return message.copyWith(id: id);
  }

  Future<void> clear() => _db.delete('messages');

  Future<void> close() => _db.close();
}
