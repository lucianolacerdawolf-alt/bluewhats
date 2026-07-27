import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../core/ble_constants.dart';
import 'chat_link.dart';
import 'framing.dart';

/// [ChatLink] do lado que iniciou a conexao (nonce menor).
///
/// Aqui enviamos com `writeCharacteristic` e recebemos pelo evento
/// `characteristicNotified`. E a imagem espelhada do [PeripheralChatLink].
class CentralChatLink implements ChatLink {
  // Posicional porque campos privados so podem virar "initializing formals"
  // em parametros posicionais -- nomeados nao podem comecar com underscore.
  CentralChatLink._(
    this._manager,
    this._peripheral,
    this._characteristic,
    this._maxPayloadSize,
  ) {
    _subscriptions.add(
      _manager.characteristicNotified.listen((e) {
        // O stream e global do manager: filtra o que nao e desta conexao nem
        // deste canal, senao mensagens de outra sessao vazariam para ca.
        if (e.peripheral.uuid != _peripheral.uuid) return;
        if (e.characteristic.uuid != BleContract.messageCharacteristic) return;

        final message = _assembler.addPacket(e.value);
        if (message != null) _incoming.add(message);
      }),
    );

    _subscriptions.add(
      _manager.connectionStateChanged.listen((e) {
        if (e.peripheral.uuid != _peripheral.uuid) return;
        if (e.state == ConnectionState.disconnected) _markDisconnected();
      }),
    );
  }

  final CentralManager _manager;
  final Peripheral _peripheral;
  final GATTCharacteristic _characteristic;
  final int _maxPayloadSize;

  final _assembler = FrameAssembler();
  final _incoming = StreamController<String>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  final _subscriptions = <StreamSubscription<void>>[];

  bool _isConnected = true;
  bool _disposed = false;

  /// Conecta, descobre o servico do BlueWhats e assina as notificacoes.
  ///
  /// Lanca [StateError] se o parceiro nao expuser o contrato esperado -- pode
  /// ser um app de versao diferente, ou outro app usando o mesmo UUID.
  static Future<CentralChatLink> connect(
    CentralManager manager,
    Peripheral peripheral,
  ) async {
    await manager.connect(peripheral);

    // MTU maior reduz o numero de pacotes por mensagem. O Android costuma
    // conceder menos que o pedido, e desde o Android 14 o primeiro pedido de
    // qualquer cliente GATT fixa o valor em 517 e os seguintes sao ignorados.
    // Por isso o retorno e usado como verdade, nunca o valor pedido.
    var mtu = BleContract.fallbackPayloadSize + 3;
    try {
      mtu = await manager.requestMTU(peripheral, mtu: BleContract.desiredMtu);
    } catch (e) {
      debugPrint('[BlueWhats] requestMTU falhou, usando minimo: $e');
    }

    final services = await manager.discoverGATT(peripheral);
    final service = services
        .where((s) => s.uuid == BleContract.chatService)
        .firstOrNull;
    if (service == null) {
      await manager.disconnect(peripheral);
      throw StateError('parceiro nao expoe o servico do BlueWhats');
    }

    final characteristic = service.characteristics
        .where((c) => c.uuid == BleContract.messageCharacteristic)
        .firstOrNull;
    if (characteristic == null) {
      await manager.disconnect(peripheral);
      throw StateError('parceiro nao expoe o canal de mensagens');
    }

    // Sem isto o outro lado pode ate chamar notifyCharacteristic, mas os
    // dados nunca chegam: o Android so entrega notificacoes a quem assinou.
    await manager.setCharacteristicNotifyState(
      peripheral,
      characteristic,
      state: true,
    );

    // Quanto realmente cabe em uma escrita, ja considerando o MTU negociado.
    var maxWrite = mtu - 3;
    try {
      maxWrite = await manager.getMaximumWriteLength(
        peripheral,
        type: GATTCharacteristicWriteType.withResponse,
      );
    } catch (e) {
      debugPrint('[BlueWhats] getMaximumWriteLength falhou, usando MTU-3: $e');
    }

    // Sem este log nao da para saber se uma mensagem foi realmente fatiada ou
    // se coube num pacote so -- e "chegou inteira" nao prova o framing.
    debugPrint('[BlueWhats] MTU=$mtu  payload maximo=$maxWrite bytes');

    return CentralChatLink._(manager, peripheral, characteristic, maxWrite);
  }

  @override
  LinkRole get role => LinkRole.central;

  @override
  String get peerId => _peripheral.uuid.toString();

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Stream<bool> get connected => _connected.stream;

  @override
  bool get isConnected => _isConnected;

  @override
  Future<void> send(String text) async {
    if (!_isConnected) throw StateError('link ja desconectado');

    final packets = MessageFraming.encode(
      text,
      messageId: _assembler.nextId(),
      maxPayloadSize: _maxPayloadSize,
    );
    debugPrint(
      '[BlueWhats] enviando ${text.length} chars em ${packets.length} pacote(s)',
    );

    for (final packet in packets) {
      // withResponse mantem a ordem e garante entrega. withoutResponse seria
      // mais rapido, mas pacotes podem se perder em silencio -- inaceitavel
      // quando cada um e um pedaco de uma mensagem.
      await _manager.writeCharacteristic(
        _peripheral,
        _characteristic,
        value: packet,
        type: GATTCharacteristicWriteType.withResponse,
      );
    }
  }

  void _markDisconnected() {
    if (!_isConnected) return;
    _isConnected = false;
    _assembler.reset();
    if (!_connected.isClosed) _connected.add(false);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _markDisconnected();

    for (final s in _subscriptions) {
      await s.cancel();
    }
    try {
      await _manager.disconnect(_peripheral);
    } catch (_) {
      // Ja pode estar desconectado -- nao ha o que fazer nem o que reportar.
    }
    await _incoming.close();
    await _connected.close();
  }
}
