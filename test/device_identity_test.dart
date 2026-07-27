import 'dart:typed_data';

import 'package:blue_whats/ble/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  group('persistencia do nonce', () {
    test('gera um nonce de 4 bytes na primeira execucao', () async {
      final id = await DeviceIdentity.load();
      expect(id.nonce, hasLength(4));
      expect(id.nonceHex, hasLength(8));
    });

    test('o mesmo nonce sobrevive entre execucoes', () async {
      // A identidade precisa ser estavel: e ela que permite reconhecer o
      // parceiro depois que o endereco BLE rotaciona.
      final first = await DeviceIdentity.load();
      final second = await DeviceIdentity.load();
      expect(second.nonceHex, first.nonceHex);
    });

    test('nonce salvo corrompido e substituido em vez de quebrar o app',
        () async {
      SharedPreferences.setMockInitialValues({'bluewhats.nonce': 'xy'});
      final id = await DeviceIdentity.load();
      expect(id.nonce, hasLength(4));
    });
  });

  group('desempate de papeis', () {
    late DeviceIdentity id;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'bluewhats.nonce': '9f7bee70'});
      id = await DeviceIdentity.load();
    });

    test('nonce menor vira Central', () {
      // Caso real observado em hardware: 9f7bee70 (POCO) vs a08aa679 (rodin).
      expect(id.shouldBeCentral(bytes([0xa0, 0x8a, 0xa6, 0x79])), isTrue);
    });

    test('nonce maior vira Peripheral', () {
      expect(id.shouldBeCentral(bytes([0x11, 0x22, 0x33, 0x44])), isFalse);
    });

    test('desempata no primeiro byte diferente', () {
      // Iguais ate o terceiro byte; o quarto decide.
      expect(id.shouldBeCentral(bytes([0x9f, 0x7b, 0xee, 0x71])), isTrue);
      expect(id.shouldBeCentral(bytes([0x9f, 0x7b, 0xee, 0x6f])), isFalse);
    });

    test('empate total nao elege Central dos dois lados', () {
      // Improvavel com 4 bytes aleatorios, mas se acontecer os dois recuam --
      // melhor um ciclo perdido do que os dois conectando ao mesmo tempo.
      expect(id.shouldBeCentral(bytes([0x9f, 0x7b, 0xee, 0x70])), isFalse);
    });

    test('os dois lados chegam sempre a papeis opostos', () async {
      // A propriedade que importa: nunca os dois iguais.
      SharedPreferences.setMockInitialValues({'bluewhats.nonce': 'a08aa679'});
      final other = await DeviceIdentity.load();

      expect(
        id.shouldBeCentral(other.nonce),
        isNot(other.shouldBeCentral(id.nonce)),
      );
    });
  });

  group('parceiro conhecido', () {
    test('reconhece o parceiro salvo mesmo com endereco novo', () async {
      // O ponto central: o endereco BLE rotaciona, o nonce nao.
      final id = await DeviceIdentity.load();
      final peer = bytes([1, 2, 3, 4]);

      await id.rememberPeer(peerNonce: peer, address: 'AA:BB:CC:DD:EE:FF');

      final reloaded = await DeviceIdentity.load();
      expect(reloaded.isKnownPeer(peer), isTrue);
      expect(reloaded.knownPeerAddress, 'AA:BB:CC:DD:EE:FF');
    });

    test('nao confunde um parceiro diferente', () async {
      final id = await DeviceIdentity.load();
      await id.rememberPeer(peerNonce: bytes([1, 2, 3, 4]), address: 'x');
      expect(id.isKnownPeer(bytes([1, 2, 3, 5])), isFalse);
    });

    test('sem parceiro salvo, nada e reconhecido', () async {
      final id = await DeviceIdentity.load();
      expect(id.knownPeerNonce, isNull);
      expect(id.knownPeerAddress, isNull);
      expect(id.isKnownPeer(bytes([1, 2, 3, 4])), isFalse);
    });

    test('forgetPeer volta ao comportamento de primeiro uso', () async {
      final id = await DeviceIdentity.load();
      await id.rememberPeer(peerNonce: bytes([1, 2, 3, 4]), address: 'x');
      await id.forgetPeer();

      expect(id.knownPeerNonce, isNull);
      expect(id.isKnownPeer(bytes([1, 2, 3, 4])), isFalse);
    });
  });

  group('preferencia pelo parceiro conhecido', () {
    final parceiro = bytes([1, 2, 3, 4]);
    final estranho = bytes([9, 9, 9, 9]);

    test('sem parceiro salvo aceita qualquer um na hora', () async {
      // Primeiro uso: nao ha com quem comparar.
      final id = await DeviceIdentity.load();
      expect(
        id.shouldConnectTo(estranho, searching: Duration.zero),
        isTrue,
      );
    });

    test('aceita o parceiro conhecido imediatamente', () async {
      final id = await DeviceIdentity.load();
      await id.rememberPeer(peerNonce: parceiro, address: 'x');
      expect(
        id.shouldConnectTo(parceiro, searching: Duration.zero),
        isTrue,
      );
    });

    test('ignora estranho durante a carencia', () async {
      // O caso que motivou tudo: duas duplas na mesma sala.
      final id = await DeviceIdentity.load();
      await id.rememberPeer(peerNonce: parceiro, address: 'x');
      expect(
        id.shouldConnectTo(estranho, searching: const Duration(seconds: 3)),
        isFalse,
      );
    });

    test('aceita estranho depois da carencia', () async {
      // Nao pode ficar preso ao primeiro parceiro para sempre: trocar de
      // dupla continua possivel, so demora alguns segundos.
      final id = await DeviceIdentity.load();
      await id.rememberPeer(peerNonce: parceiro, address: 'x');
      expect(
        id.shouldConnectTo(estranho, searching: const Duration(seconds: 9)),
        isTrue,
      );
    });

    test('a carencia nao atrasa o parceiro conhecido', () async {
      final id = await DeviceIdentity.load();
      await id.rememberPeer(peerNonce: parceiro, address: 'x');
      for (final s in [0, 1, 5, 30]) {
        expect(
          id.shouldConnectTo(parceiro, searching: Duration(seconds: s)),
          isTrue,
          reason: 'aos ${s}s',
        );
      }
    });
  });
}
