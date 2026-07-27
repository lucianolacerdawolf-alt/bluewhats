import 'dart:typed_data';

import 'package:blue_whats/ble/framing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Simula a viagem completa: encode -> pacotes -> assembler -> texto.
  String? roundTrip(String text, {int maxPayloadSize = 20}) {
    final assembler = FrameAssembler();
    final packets = MessageFraming.encode(
      text,
      messageId: assembler.nextId(),
      maxPayloadSize: maxPayloadSize,
    );
    String? result;
    for (final p in packets) {
      result = assembler.addPacket(p) ?? result;
    }
    return result;
  }

  group('ida e volta', () {
    test('mensagem curta cabe em um pacote so', () {
      final packets = MessageFraming.encode(
        'Oi',
        messageId: 0,
        maxPayloadSize: 20,
      );
      expect(packets, hasLength(1));
      expect(roundTrip('Oi'), 'Oi');
    });

    test('mensagem vazia sobrevive', () {
      // Caso limite: sem um pacote, o outro lado nunca receberia nada.
      expect(MessageFraming.encode('', messageId: 0, maxPayloadSize: 20),
          hasLength(1));
      expect(roundTrip(''), '');
    });

    test('mensagem de 500 caracteres e remontada intacta', () {
      // O cenario do plano: o MTU minimo forcaria dezenas de pacotes.
      final long = List.generate(500, (i) => 'abcde'[i % 5]).join();
      expect(long.length, 500);
      expect(roundTrip(long), long);
    });

    test('acentos e emoji nao quebram no corte dos chunks', () {
      // A razao de codificar para UTF-8 antes de fatiar: um emoji ocupa
      // 4 bytes e seria partido ao meio se fatiassemos a String.
      const text = 'Ola! Tudo bem? Vamos testar acentuacao: '
          'ção ãé çü — e emoji 👋🏽🎉🇧🇷 no meio do texto.';
      expect(roundTrip(text), text);
    });

    test('funciona com MTU grande (um pacote unico)', () {
      final long = 'x' * 400;
      final packets = MessageFraming.encode(
        long,
        messageId: 0,
        maxPayloadSize: 512,
      );
      expect(packets, hasLength(1));
      expect(roundTrip(long, maxPayloadSize: 512), long);
    });
  });

  group('mensagens concorrentes', () {
    test('duas mensagens intercaladas nao se misturam', () {
      final assembler = FrameAssembler();
      final a = MessageFraming.encode('AAAAAAAAAAAAAAAAAAAA',
          messageId: 1, maxPayloadSize: 10);
      final b = MessageFraming.encode('BBBBBBBBBBBBBBBBBBBB',
          messageId: 2, maxPayloadSize: 10);
      expect(a.length, greaterThan(1));
      expect(b.length, greaterThan(1));

      // Intercala os pacotes das duas mensagens.
      final results = <String>[];
      for (var i = 0; i < a.length + b.length; i++) {
        final packet = i.isEven
            ? (i ~/ 2 < a.length ? a[i ~/ 2] : null)
            : (i ~/ 2 < b.length ? b[i ~/ 2] : null);
        if (packet == null) continue;
        final done = assembler.addPacket(packet);
        if (done != null) results.add(done);
      }

      expect(results, containsAll(['AAAAAAAAAAAAAAAAAAAA', 'BBBBBBBBBBBBBBBBBBBB']));
    });

    test('pacotes fora de ordem sao remontados corretamente', () {
      final assembler = FrameAssembler();
      final packets = MessageFraming.encode(
        'mensagem fora de ordem para testar',
        messageId: 7,
        maxPayloadSize: 10,
      );
      String? result;
      for (final p in packets.reversed) {
        result = assembler.addPacket(p) ?? result;
      }
      expect(result, 'mensagem fora de ordem para testar');
    });
  });

  group('robustez contra lixo', () {
    test('pacote menor que o cabecalho e ignorado', () {
      expect(FrameAssembler().addPacket(Uint8List.fromList([1, 2])), isNull);
    });

    test('total zero e ignorado', () {
      // Um vizinho transmitindo lixo no mesmo UUID nao pode derrubar o chat.
      final p = Uint8List.fromList([0, 1, 0, 0, 65]);
      expect(FrameAssembler().addPacket(p), isNull);
    });

    test('indice maior que o total e ignorado', () {
      final p = Uint8List.fromList([0, 1, 5, 2, 65]);
      expect(FrameAssembler().addPacket(p), isNull);
    });

    test('bytes UTF-8 invalidos nao lancam excecao', () {
      // 0xFF nunca aparece em UTF-8 valido.
      final p = Uint8List.fromList([0, 1, 0, 1, 0xFF, 0xFE]);
      expect(FrameAssembler().addPacket(p), isNull);
    });
  });

  group('estado do assembler', () {
    test('reset descarta mensagens pela metade', () {
      final assembler = FrameAssembler();
      final packets = MessageFraming.encode(
        'mensagem longa o suficiente para varios chunks',
        messageId: 3,
        maxPayloadSize: 10,
      );
      assembler.addPacket(packets.first);
      expect(assembler.pendingCount, 1);

      assembler.reset();
      expect(assembler.pendingCount, 0);
    });

    test('nextId circula dentro de 16 bits sem repetir de imediato', () {
      final assembler = FrameAssembler();
      final ids = List.generate(2000, (_) => assembler.nextId());
      expect(ids.toSet(), hasLength(2000));
      expect(ids.every((id) => id >= 0 && id <= 0xFFFF), isTrue);
    });
  });

  group('limites', () {
    test('MTU pequeno demais para caber cabecalho + dados e rejeitado', () {
      expect(
        () => MessageFraming.encode('oi', messageId: 0, maxPayloadSize: 4),
        throwsArgumentError,
      );
    });

    test('mensagem que estoura 255 chunks e rejeitada', () {
      // Com 1 byte util por pacote, 300 caracteres pedem 300 chunks.
      expect(
        () => MessageFraming.encode('x' * 300, messageId: 0, maxPayloadSize: 5),
        throwsArgumentError,
      );
    });
  });
}
