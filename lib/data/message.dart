/// Uma mensagem do chat.
class Message {
  const Message({
    required this.text,
    required this.mine,
    required this.sentAt,
    this.id,
  });

  /// `null` enquanto a mensagem ainda nao foi gravada no banco.
  final int? id;

  final String text;

  /// `true` se fui eu que enviei. Decide o lado do balao na tela.
  final bool mine;

  final DateTime sentAt;

  Message copyWith({int? id}) => Message(
    id: id ?? this.id,
    text: text,
    mine: mine,
    sentAt: sentAt,
  );

  Map<String, Object?> toRow() => {
    'text': text,
    // SQLite nao tem tipo booleano: 0/1 e a convencao.
    'mine': mine ? 1 : 0,
    'sent_at': sentAt.millisecondsSinceEpoch,
  };

  factory Message.fromRow(Map<String, Object?> row) => Message(
    id: row['id'] as int?,
    text: row['text'] as String,
    mine: (row['mine'] as int) == 1,
    sentAt: DateTime.fromMillisecondsSinceEpoch(row['sent_at'] as int),
  );
}
