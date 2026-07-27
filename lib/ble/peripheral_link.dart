import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../core/ble_constants.dart';
import 'chat_link.dart';
import 'framing.dart';

/// [ChatLink] do lado que estava anunciando e foi conectado (nonce maior).
///
/// Espelho do `CentralChatLink`: aqui enviamos com `notifyCharacteristic` e
/// recebemos pelo evento `characteristicWriteRequested`.
///
/// Uma assimetria real do BLE aparece aqui: o Central precisa **assinar** as
/// notificacoes antes de conseguir receber qualquer coisa. Ate que isso
/// aconteca, chamar `notifyCharacteristic` nao entrega nada -- e nao da erro.
/// Por isso [waitSubscription] existe.
class PeripheralChatLink implements ChatLink {
  /// [characteristic] precisa ser **a mesma instancia** passada ao
  /// `addService`, nunca uma copia com o mesmo UUID.
  ///
  /// O plugin resolve a characteristic pelo `hashCode` do objeto Dart. Com uma
  /// copia, `notifyCharacteristic` nao acha o registro e **retorna sem lancar
  /// erro** -- a mensagem some sem deixar rastro.
  //
  // Posicional porque campos privados so podem virar "initializing formals"
  // em parametros posicionais -- nomeados nao podem comecar com underscore.
  PeripheralChatLink(
    this._manager,
    this._central,
    this._characteristic,
    this._maxPayloadSize,
  ) {
    _subscriptions.add(
      _manager.characteristicWriteRequested.listen((e) async {
        if (e.central.uuid != _central.uuid) return;
        if (e.characteristic.uuid != BleContract.messageCharacteristic) return;

        // Responder e obrigatorio em escrita withResponse: sem isso o Central
        // fica esperando o ACK e para de enviar os pacotes seguintes,
        // travando a mensagem pela metade.
        try {
          await _manager.respondWriteRequest(e.request);
        } catch (err) {
          debugPrint('[BlueWhats] falha ao responder write: $err');
        }

        final message = _assembler.addPacket(e.request.value);
        if (message != null) _incoming.add(message);
      }),
    );

    _subscriptions.add(
      _manager.characteristicNotifyStateChanged.listen((e) {
        if (e.central.uuid != _central.uuid) return;
        if (e.characteristic.uuid != BleContract.messageCharacteristic) return;
        _subscribed = e.state;
        if (e.state && !_subscriptionReady.isCompleted) {
          _subscriptionReady.complete();
        }
      }),
    );

    _subscriptions.add(
      _manager.connectionStateChanged.listen((e) {
        if (e.central.uuid != _central.uuid) return;
        if (e.state == ConnectionState.disconnected) _markDisconnected();
      }),
    );
  }

  final PeripheralManager _manager;
  final Central _central;
  final GATTCharacteristic _characteristic;
  int _maxPayloadSize;

  final _assembler = FrameAssembler();
  final _incoming = StreamController<String>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  final _subscriptions = <StreamSubscription<void>>[];
  final _subscriptionReady = Completer<void>();

  bool _subscribed = false;
  bool _isConnected = true;
  bool _disposed = false;

  /// Espera o Central assinar as notificacoes.
  ///
  /// Enviar antes disso perde a mensagem em silencio. Devolve `false` se o
  /// tempo esgotar -- o parceiro provavelmente nao e o nosso app.
  Future<bool> waitSubscription({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_subscribed) return true;
    try {
      await _subscriptionReady.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Le do sistema quantos bytes cabem em uma notificacao.
  ///
  /// So faz sentido depois que o MTU foi negociado, o que acontece por
  /// iniciativa do Central. Falhar aqui nao e critico: o valor inicial
  /// conservador continua valendo.
  Future<void> refreshPayloadSize() async {
    try {
      _maxPayloadSize = await _manager.getMaximumNotifyLength(_central);
      debugPrint('[BlueWhats] payload maximo de notify=$_maxPayloadSize bytes');
    } catch (e) {
      debugPrint('[BlueWhats] getMaximumNotifyLength falhou: $e');
    }
  }

  @override
  LinkRole get role => LinkRole.peripheral;

  @override
  String get peerId => _central.uuid.toString();

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Stream<bool> get connected => _connected.stream;

  @override
  bool get isConnected => _isConnected;

  @override
  Future<void> send(String text) async {
    if (!_isConnected) throw StateError('link ja desconectado');
    if (!_subscribed) {
      throw StateError('o outro aparelho ainda nao assinou o canal');
    }

    final packets = MessageFraming.encode(
      text,
      messageId: _assembler.nextId(),
      maxPayloadSize: _maxPayloadSize,
    );
    debugPrint(
      '[BlueWhats] enviando ${text.length} chars em ${packets.length} pacote(s)',
    );

    for (final packet in packets) {
      await _manager.notifyCharacteristic(
        _central,
        _characteristic,
        value: packet,
      );
    }
  }

  void _markDisconnected() {
    if (!_isConnected) return;
    _isConnected = false;
    _subscribed = false;
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
      await _manager.disconnect(_central);
    } catch (_) {
      // Ja pode estar desconectado -- nao ha o que fazer nem o que reportar.
    }
    await _incoming.close();
    await _connected.close();
  }
}
