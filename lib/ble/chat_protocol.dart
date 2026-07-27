/// O que um quadro carrega.
enum ChatFrameType {
  /// Texto digitado pelo usuario.
  message,

  /// Apelido de quem enviou, trocado logo apos conectar.
  nickname,
}

/// Uma unidade de conversa entre os dois aparelhos.
///
/// ## Por que existe uma camada aqui
///
/// O canal BLE transporta apenas bytes, e o `framing.dart` os remonta em
/// strings -- ele e um cano burro, sem opiniao sobre o conteudo. Mas agora
/// precisamos trafegar duas coisas diferentes pelo mesmo cano: o texto do chat
/// e o apelido de cada lado.
///
/// O apelido nao pode viajar no advertising: o pacote primario tem 31 bytes e
/// ja usa 29 (flags 3 + service UUID de 128 bits 18 + manufacturer data 8). O
/// plugin so conseguiria anuncia-lo chamando `adapter.setName()`, que renomeia
/// o Bluetooth do aparelho inteiro -- efeito de sistema, fora do nosso app.
/// Por isso o apelido e trocado por GATT, depois da conexao, e precisa de um
/// jeito de se distinguir de uma mensagem comum.
///
/// ## O formato
///
/// Um caractere de tipo seguido do conteudo:
///
/// ```
///   M<texto>       mensagem
///   N<apelido>     apelido
/// ```
///
/// Nao ha ambiguidade com o que o usuario digita: todo quadro enviado recebe o
/// prefixo, e todo quadro recebido tem o prefixo removido. Um texto do usuario
/// nunca chega ao outro lado sem passar por aqui.
class ChatFrame {
  const ChatFrame(this.type, this.text);

  const ChatFrame.message(this.text) : type = ChatFrameType.message;
  const ChatFrame.nickname(this.text) : type = ChatFrameType.nickname;

  final ChatFrameType type;
  final String text;

  static const _messageTag = 'M';
  static const _nicknameTag = 'N';

  /// Serializa para o formato de fio.
  String encode() => switch (type) {
    ChatFrameType.message => '$_messageTag$text',
    ChatFrameType.nickname => '$_nicknameTag$text',
  };

  /// Le um quadro recebido.
  ///
  /// Devolve `null` para entrada vazia ou com tipo desconhecido -- outro app
  /// usando o mesmo UUID, ou uma versao incompativel. Descartar e mais seguro
  /// que exibir lixo como se fosse mensagem.
  static ChatFrame? decode(String raw) {
    if (raw.isEmpty) return null;
    final body = raw.substring(1);
    return switch (raw[0]) {
      _messageTag => ChatFrame.message(body),
      _nicknameTag => ChatFrame.nickname(body),
      _ => null,
    };
  }

  @override
  String toString() => 'ChatFrame(${type.name}, "$text")';
}
