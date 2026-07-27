import 'package:blue_whats/ble/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ida e volta', () {
    test('mensagem sobrevive intacta', () {
      final decoded = ChatFrame.decode(const ChatFrame.message('Oi!').encode());
      expect(decoded?.type, ChatFrameType.message);
      expect(decoded?.text, 'Oi!');
    });

    test('apelido sobrevive intacto', () {
      final decoded = ChatFrame.decode(
        const ChatFrame.nickname('Luciano').encode(),
      );
      expect(decoded?.type, ChatFrameType.nickname);
      expect(decoded?.text, 'Luciano');
    });

    test('acentos e emoji atravessam', () {
      const text = 'Ola, tudo bem? ção ãé 👋🏽🇧🇷';
      expect(ChatFrame.decode(const ChatFrame.message(text).encode())?.text,
          text);
    });

    test('mensagem vazia continua sendo mensagem', () {
      final decoded = ChatFrame.decode(const ChatFrame.message('').encode());
      expect(decoded?.type, ChatFrameType.message);
      expect(decoded?.text, '');
    });
  });

  group('sem ambiguidade com o texto do usuario', () {
    // A preocupacao obvia ao usar prefixo de um caractere: e se o usuario
    // digitar justamente ele? Nao ha risco, porque todo envio e prefixado e
    // todo recebimento tem o prefixo removido.
    test('texto comecando com N vira mensagem, nao apelido', () {
      final decoded = ChatFrame.decode(
        const ChatFrame.message('Nossa, que legal').encode(),
      );
      expect(decoded?.type, ChatFrameType.message);
      expect(decoded?.text, 'Nossa, que legal');
    });

    test('texto comecando com M continua mensagem', () {
      final decoded = ChatFrame.decode(
        const ChatFrame.message('Manda ver').encode(),
      );
      expect(decoded?.type, ChatFrameType.message);
      expect(decoded?.text, 'Manda ver');
    });

    test('apelido que parece comando nao confunde', () {
      final decoded = ChatFrame.decode(
        const ChatFrame.nickname('Marcos').encode(),
      );
      expect(decoded?.type, ChatFrameType.nickname);
      expect(decoded?.text, 'Marcos');
    });
  });

  group('robustez', () {
    test('entrada vazia e descartada', () {
      expect(ChatFrame.decode(''), isNull);
    });

    test('tipo desconhecido e descartado', () {
      // Outro app no mesmo UUID, ou versao incompativel: descartar e melhor
      // que exibir lixo como se fosse mensagem.
      expect(ChatFrame.decode('Xqualquer coisa'), isNull);
    });

    test('so o prefixo devolve conteudo vazio, nao null', () {
      expect(ChatFrame.decode('M')?.text, '');
      expect(ChatFrame.decode('N')?.text, '');
    });
  });
}
