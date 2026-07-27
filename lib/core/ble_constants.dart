import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// O "contrato" BLE do BlueWhats.
///
/// Estes valores sao o endereco combinado onde os dois celulares se encontram.
/// Ambos os aparelhos rodam o mesmo app, entao usam exatamente os mesmos
/// UUIDs: um anuncia o [chatService] e o outro filtra o scan por ele,
/// ignorando todo o resto do trafego Bluetooth ao redor.
///
/// NAO altere estes valores depois que o app estiver instalado em dois
/// aparelhos -- versoes com UUIDs diferentes nunca se enxergam.
class BleContract {
  BleContract._();

  /// Identifica o app no ar. E o que o advertiser publica e o scanner procura.
  static final UUID chatService = UUID.fromString(
    'ee9af195-b5b2-4e3a-9929-203e60ab690f',
  );

  /// Canal unico de mensagens, usado nas duas direcoes:
  /// - Central -> Peripheral: `write`
  /// - Peripheral -> Central: `notify`
  static final UUID messageCharacteristic = UUID.fromString(
    '7de0fc79-f70a-45c0-97b3-303a29192dc3',
  );

  // Havia aqui um `nicknameCharacteristic`, previsto para trocar o apelido do
  // usuario apos a conexao (ele nao cabe no advertising -- ver [nonceLength]).
  // Removido por nunca ter sido usado: UUID reservado sem implementacao vira
  // ruido, e gerar outro na hora que a funcionalidade existir custa nada.

  // ===========================================================================
  // Desempate de papeis (nonce)
  // ===========================================================================

  /// ID de fabricante usado para carregar o nonce no advertising.
  ///
  /// 0xFFFF e o valor que o Bluetooth SIG reserva para testes e uso interno,
  /// entao nao colide com nenhum fabricante real.
  static const int manufacturerId = 0xFFFF;

  /// Tamanho do nonce aleatorio de desempate.
  ///
  /// O orcamento do advertising legado e de 31 bytes e ja esta praticamente
  /// cheio:
  ///
  /// ```
  ///   flags .......................  3 bytes  (o Android adiciona sozinho)
  ///   service UUID de 128 bits .... 18 bytes  (2 de cabecalho + 16 do UUID)
  ///   manufacturer data ...........  8 bytes  (2 cabecalho + 2 id + 4 nonce)
  ///                                 --------
  ///                                 29 bytes
  /// ```
  ///
  /// Por isso o nome do dispositivo fica de fora do anuncio: nao ha espaco.
  /// Aumentar este valor acima de 4 estoura o pacote e o advertising falha.
  static const int nonceLength = 4;

  // ===========================================================================
  // Transporte
  // ===========================================================================

  /// MTU pedido logo apos conectar. O Android costuma conceder menos que isso,
  /// por isso o framing continua sendo necessario (ver `ble/framing.dart`).
  static const int desiredMtu = 512;

  /// Payload assumido quando a negociacao de MTU falha:
  /// 23 bytes de MTU padrao - 3 bytes de cabecalho ATT.
  static const int fallbackPayloadSize = 20;
}
