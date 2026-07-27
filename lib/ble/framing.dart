import 'dart:convert';
import 'dart:typed_data';

/// Quebra mensagens em pacotes que cabem no BLE e remonta do outro lado.
///
/// ## Por que isso existe
///
/// O BLE nao transmite "uma mensagem": ele transmite pacotes pequenos. Com o
/// MTU padrao de 23 bytes sobram apenas 20 bytes uteis por pacote -- menos que
/// uma frase curta de chat. Pedimos um MTU maior ao conectar, mas o Android
/// pode conceder menos, entao o codigo nunca pode assumir que a mensagem
/// inteira coube em um pacote so.
///
/// ## O formato
///
/// Cada pacote carrega um cabecalho de 4 bytes:
///
/// ```
///   byte 0-1 : id da mensagem  (uint16 big-endian)
///   byte 2   : indice do chunk (uint8)
///   byte 3   : total de chunks (uint8)
///   byte 4+  : pedaco do payload UTF-8
/// ```
///
/// O `id` permite que o receptor nao misture duas mensagens que cheguem
/// intercaladas. `indice`/`total` dizem quando a mensagem esta completa.
///
/// O limite de 255 chunks e proposital: com o MTU minimo de 20 bytes isso da
/// ~4 KB por mensagem, muito acima de qualquer mensagem de chat, e mantem o
/// cabecalho em 4 bytes.
class MessageFraming {
  MessageFraming._();

  /// Tamanho do cabecalho em cada pacote.
  static const int headerSize = 4;

  /// Maximo de chunks por mensagem, imposto pelo campo de 1 byte.
  static const int maxChunks = 255;

  /// Quebra [text] em pacotes de no maximo [maxPayloadSize] bytes cada.
  ///
  /// [messageId] deve ser diferente a cada mensagem enviada, para o receptor
  /// conseguir separar mensagens concorrentes. Use [FrameAssembler.nextId].
  ///
  /// Lanca [ArgumentError] se [maxPayloadSize] nao deixar espaco para dados
  /// alem do cabecalho, ou se a mensagem for grande demais para 255 chunks.
  static List<Uint8List> encode(
    String text, {
    required int messageId,
    required int maxPayloadSize,
  }) {
    final chunkSize = maxPayloadSize - headerSize;
    if (chunkSize <= 0) {
      throw ArgumentError.value(
        maxPayloadSize,
        'maxPayloadSize',
        'precisa ser maior que o cabecalho de $headerSize bytes',
      );
    }

    // Codificamos para UTF-8 ANTES de fatiar. Fatiar a String e depois
    // codificar quebraria caracteres multibyte (acentos, emoji) ao meio.
    final bytes = utf8.encode(text);

    // Uma mensagem vazia ainda precisa de um pacote, senao o outro lado nunca
    // recebe nada e a mensagem sabota o contador de chunks.
    final total = bytes.isEmpty ? 1 : (bytes.length / chunkSize).ceil();
    if (total > maxChunks) {
      throw ArgumentError(
        'mensagem de ${bytes.length} bytes precisa de $total chunks, '
        'acima do limite de $maxChunks',
      );
    }

    return List.generate(total, (i) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, bytes.length);
      final slice = bytes.sublist(start, end);

      final packet = Uint8List(headerSize + slice.length);
      packet[0] = (messageId >> 8) & 0xFF;
      packet[1] = messageId & 0xFF;
      packet[2] = i;
      packet[3] = total;
      packet.setRange(headerSize, packet.length, slice);
      return packet;
    });
  }
}

/// Remonta pacotes recebidos de volta em mensagens completas.
///
/// Mantem estado entre chamadas, entao use uma instancia por conexao e
/// descarte quando o link cair (ver [reset]).
class FrameAssembler {
  /// Chunks recebidos por id de mensagem, ainda incompletos.
  final Map<int, List<Uint8List?>> _pending = {};

  int _nextId = 0;

  /// Gera o proximo id de mensagem, circulando dentro do campo de 16 bits.
  int nextId() {
    final id = _nextId;
    _nextId = (_nextId + 1) & 0xFFFF;
    return id;
  }

  /// Alimenta um pacote recebido.
  ///
  /// Devolve a mensagem completa quando o ultimo chunk que faltava chega, ou
  /// `null` enquanto ainda faltarem pedacos.
  ///
  /// Pacotes malformados sao descartados devolvendo `null`, nunca lancando --
  /// um vizinho transmitindo lixo no mesmo UUID nao pode derrubar o chat.
  String? addPacket(Uint8List packet) {
    if (packet.length < MessageFraming.headerSize) return null;

    final messageId = (packet[0] << 8) | packet[1];
    final index = packet[2];
    final total = packet[3];

    if (total == 0 || index >= total) return null;

    final slots = _pending.putIfAbsent(
      messageId,
      () => List<Uint8List?>.filled(total, null),
    );

    // O total mudou no meio da mensagem: os pacotes nao pertencem ao mesmo
    // envio (id reciclado cedo demais, ou dado corrompido). Recomeca.
    if (slots.length != total) {
      _pending[messageId] = List<Uint8List?>.filled(total, null)
        ..[index] = Uint8List.sublistView(packet, MessageFraming.headerSize);
      return null;
    }

    slots[index] = Uint8List.sublistView(packet, MessageFraming.headerSize);

    if (slots.any((s) => s == null)) return null;

    _pending.remove(messageId);
    final builder = BytesBuilder(copy: false);
    for (final slot in slots) {
      builder.add(slot!);
    }

    try {
      return utf8.decode(builder.takeBytes());
    } on FormatException {
      // Bytes que nao formam UTF-8 valido: descarta em vez de derrubar o app.
      return null;
    }
  }

  /// Quantas mensagens estao pela metade agora. Util em log e diagnostico.
  int get pendingCount => _pending.length;

  /// Descarta tudo que estava pela metade.
  ///
  /// Chame ao perder a conexao: os chunks que faltavam nunca vao chegar, e
  /// segura-los so vazaria memoria e arriscaria colidir com ids reciclados na
  /// proxima sessao.
  void reset() => _pending.clear();
}
