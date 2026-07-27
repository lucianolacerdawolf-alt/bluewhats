import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/ble_constants.dart';

/// Identidade estavel deste aparelho no BlueWhats.
///
/// ## Por que nao usamos o endereco Bluetooth
///
/// Duas razoes, as duas verificadas na pratica:
///
/// 1. **O aparelho nao sabe o proprio endereco.** Desde o Android 6, ler o MAC
///    do proprio Bluetooth devolve `02:00:00:00:00:00` para qualquer app.
///
/// 2. **O endereco do outro tambem nao serve como identidade.** O Android
///    anuncia com *Resolvable Private Address*, que rotaciona periodicamente
///    para impedir rastreamento. Observado no teste em hardware: o mesmo
///    aparelho, na mesma sessao do app, foi visto como `669e014b` e minutos
///    depois como `faec8ae9`. Sem pareamento nao ha troca de IRK, entao nao
///    existe como resolver o endereco de volta para o aparelho real.
///
/// O nonce resolve os dois problemas: e gerado pelo app, viaja no advertising,
/// e -- por ser persistido aqui -- sobrevive a reinstalacoes de sessao.
///
/// Ele cumpre dois papeis:
/// - **desempate**: quem tem o nonce menor assume o papel de Central;
/// - **reconhecimento**: permite reconectar automaticamente a um parceiro ja
///   conhecido, mesmo depois do endereco BLE ter rotacionado.
class DeviceIdentity {
  DeviceIdentity._(this.nonce, this._prefs);

  static const _nonceKey = 'bluewhats.nonce';
  static const _peerNonceKey = 'bluewhats.peer_nonce';
  static const _peerAddressKey = 'bluewhats.peer_address';
  static const _nicknameKey = 'bluewhats.nickname';

  /// Limite do apelido.
  ///
  /// Ele viaja pelo canal de mensagens, entao caberia bem mais -- o corte e
  /// para caber na tela sem empurrar o resto da barra de status para fora.
  static const nicknameMaxLength = 24;

  /// Nonce deste aparelho, estavel entre execucoes do app.
  final Uint8List nonce;

  final SharedPreferences _prefs;

  /// Carrega o nonce salvo, ou gera e persiste um novo na primeira execucao.
  static Future<DeviceIdentity> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_nonceKey);

    if (saved != null && saved.length == BleContract.nonceLength * 2) {
      return DeviceIdentity._(_fromHex(saved), prefs);
    }

    final rng = Random.secure();
    final fresh = Uint8List.fromList(
      List.generate(BleContract.nonceLength, (_) => rng.nextInt(256)),
    );
    await prefs.setString(_nonceKey, _toHex(fresh));
    return DeviceIdentity._(fresh, prefs);
  }

  /// Nonce do ultimo parceiro conhecido, se houver.
  Uint8List? get knownPeerNonce {
    final hex = _prefs.getString(_peerNonceKey);
    return hex == null ? null : _fromHex(hex);
  }

  /// Endereco BLE do ultimo parceiro.
  ///
  /// Serve apenas como **atalho de curto prazo**: enquanto o endereco nao
  /// rotacionar, da para reconectar direto e pular a descoberta. Depois da
  /// rotacao ele fica invalido e o ciclo completo volta a ser necessario --
  /// por isso quem usa isto precisa sempre ter o caminho de fallback.
  String? get knownPeerAddress => _prefs.getString(_peerAddressKey);

  /// Guarda o parceiro apos uma conexao bem-sucedida.
  Future<void> rememberPeer({
    required Uint8List peerNonce,
    required String address,
  }) async {
    await _prefs.setString(_peerNonceKey, _toHex(peerNonce));
    await _prefs.setString(_peerAddressKey, address);
  }

  /// `true` se este nonce e o do parceiro que ja conhecemos.
  bool isKnownPeer(Uint8List peerNonce) {
    final known = knownPeerNonce;
    if (known == null || known.length != peerNonce.length) return false;
    for (var i = 0; i < known.length; i++) {
      if (known[i] != peerNonce[i]) return false;
    }
    return true;
  }

  /// Apelido escolhido pelo usuario, ou `null` se ele ainda nao escolheu.
  ///
  /// E um apelido **do app**, nao o nome Bluetooth do aparelho: escrever no
  /// nome do sistema mudaria como o celular aparece no carro, no fone e em
  /// qualquer outro pareamento. Por isso ele viaja por GATT depois da conexao,
  /// e nao no advertising.
  String? get nickname {
    final saved = _prefs.getString(_nicknameKey);
    return (saved == null || saved.isEmpty) ? null : saved;
  }

  Future<void> setNickname(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await _prefs.remove(_nicknameKey);
      return;
    }
    await _prefs.setString(
      _nicknameKey,
      trimmed.length > nicknameMaxLength
          ? trimmed.substring(0, nicknameMaxLength)
          : trimmed,
    );
  }

  /// Quanto tempo esperamos pelo parceiro conhecido antes de aceitar outro.
  ///
  /// Curto demais e a preferencia nao serve para nada; longo demais e o
  /// usuario acha que o app travou ao tentar conversar com alguem novo.
  static const knownPeerGrace = Duration(seconds: 8);

  /// Decide se vale conectar neste par agora.
  ///
  /// Sem isto o app conecta em **qualquer** aparelho anunciando o nosso UUID.
  /// Com duas duplas na mesma sala, elas se conectam cruzado -- ao acaso, com
  /// quem aparecer primeiro no scan.
  ///
  /// A regra tem tres casos:
  /// - **sem parceiro salvo**: aceita qualquer um (e o primeiro uso);
  /// - **e o parceiro conhecido**: aceita na hora;
  /// - **e um estranho**: espera [knownPeerGrace] procurando o conhecido, e so
  ///   entao aceita. A carencia evita ficar preso ao primeiro parceiro para
  ///   sempre -- trocar de dupla continua possivel, so demora alguns segundos.
  ///
  /// [searching] e ha quanto tempo o scan atual esta rodando.
  bool shouldConnectTo(
    Uint8List peerNonce, {
    required Duration searching,
    Duration grace = knownPeerGrace,
  }) {
    if (knownPeerNonce == null) return true;
    if (isKnownPeer(peerNonce)) return true;
    return searching >= grace;
  }

  /// Esquece o parceiro salvo, voltando ao comportamento de primeiro uso.
  Future<void> forgetPeer() async {
    await _prefs.remove(_peerNonceKey);
    await _prefs.remove(_peerAddressKey);
  }

  /// Desempate deterministico: o nonce menor assume o papel de Central.
  ///
  /// Comparar byte a byte da o mesmo veredito nos dois aparelhos, sem que eles
  /// precisem combinar nada. Sem isso, os dois tentariam conectar ao mesmo
  /// tempo ou os dois ficariam esperando.
  bool shouldBeCentral(Uint8List peerNonce) {
    final len = min(nonce.length, peerNonce.length);
    for (var i = 0; i < len; i++) {
      if (nonce[i] != peerNonce[i]) return nonce[i] < peerNonce[i];
    }
    // Empate total e praticamente impossivel com 4 bytes aleatorios, mas se
    // acontecer os dois recuam para Peripheral e o proximo scan resolve --
    // melhor um ciclo perdido do que os dois conectando ao mesmo tempo.
    return false;
  }

  String get nonceHex => _toHex(nonce);

  static String _toHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
