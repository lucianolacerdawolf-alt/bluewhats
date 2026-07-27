import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../core/ble_constants.dart';
import '../core/bluetooth_switch.dart';
import '../core/permissions.dart';
import 'central_link.dart';
import 'chat_link.dart';
import 'chat_protocol.dart';
import 'device_identity.dart';
import 'peripheral_link.dart';

/// Em que ponto do ciclo de vida a conexao esta.
enum ConnectionPhase {
  /// Nada rodando ainda.
  idle,

  /// Pedindo permissoes e ligando o radio.
  preparing,

  /// Anunciando e escaneando ao mesmo tempo, procurando o parceiro.
  searching,

  /// Achou o parceiro e esta estabelecendo o link.
  connecting,

  /// Link de pe -- da para conversar.
  connected,

  /// Perdeu a conexao e vai tentar de novo.
  reconnecting,

  /// Parou por erro. [ConnectionManager.error] explica.
  failed,
}

/// Orquestra o modo de duplo papel: anuncia e escaneia ao mesmo tempo,
/// desempata quem conecta em quem, e reconecta sozinho quando o sinal cai.
///
/// A UI observa [phase] e [link]; ela nunca precisa saber qual papel o
/// aparelho assumiu, porque o [ChatLink] esconde essa diferenca.
///
/// ## A ordem de inicializacao e obrigatoria
///
/// Permissoes -> managers -> `poweredOn` -> registrar servico -> anunciar.
/// Criar os managers antes das permissoes deixa o `PeripheralManager` preso em
/// `unauthorized`, e o servidor GATT nunca abre. Ver [BlePermissions].
class ConnectionManager extends ChangeNotifier {
  ConnectionManager();

  CentralManager? _central;
  PeripheralManager? _peripheral;
  DeviceIdentity? _identity;

  /// A MESMA instancia registrada em [_publishService].
  ///
  /// Nao pode ser recriada na hora de notificar: o plugin identifica a
  /// characteristic pelo `hashCode` do objeto Dart, nao pelo UUID --
  ///
  /// ```dart
  /// final hashCodeArgs = characteristic.hashCode;
  /// final cccValue = _retrieveCCCValue(addressArgs, hashCodeArgs);
  /// if (notificationDisabled) return;   // sai sem lancar nada
  /// ```
  ///
  /// Com um objeto novo a busca falha e o `notifyCharacteristic` **retorna em
  /// silencio**: nenhum erro, nenhuma entrega. Foi assim que o sentido
  /// Peripheral -> Central ficou mudo enquanto o outro funcionava.
  GATTCharacteristic? _messageCharacteristic;

  final _subscriptions = <StreamSubscription<void>>[];

  ChatLink? _link;
  ConnectionPhase _phase = ConnectionPhase.idle;
  String? _error;

  /// Nonce do parceiro visto no advertising, guardado para persistir depois
  /// que a conexao vingar.
  Uint8List? _peerNonce;

  /// Evita duas tentativas de conexao simultaneas para o mesmo par.
  bool _connecting = false;

  bool _advertising = false;
  bool _scanning = false;
  bool _disposed = false;

  /// `true` enquanto [start] conduz a inicializacao.
  ///
  /// O listener de radio precisa recuar nessa janela. Sem isto os dois caminhos
  /// chamam `startAdvertising` concorrentemente e o segundo estoura com
  /// `ADVERTISE_FAILED_ALREADY_STARTED` (codigo 3) -- as flags `_advertising` e
  /// `_scanning` sozinhas nao bastam, porque so sao marcadas *depois* do await.
  bool _starting = false;

  /// Se o servico GATT esta registrado no servidor **atual**.
  ///
  /// Desligar o Bluetooth faz o plugin fechar o servidor GATT; ao religar ele
  /// abre um servidor novo e **vazio**. O registro anterior nao volta sozinho,
  /// entao precisa ser refeito -- senao o aparelho anuncia sem o servico e o
  /// outro lado conecta e nao encontra o canal de mensagens.
  bool _servicePublished = false;

  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  /// Quando o scan atual comecou. Alimenta a carencia do parceiro conhecido.
  DateTime? _searchStartedAt;

  /// Mensagens ja separadas dos quadros de controle (apelido).
  ///
  /// A tela escuta este stream em vez do link direto: assim ela nao precisa
  /// reassinar a cada reconexao -- cada queda cria um [ChatLink] novo, e uma
  /// inscricao esquecida no link antigo duplicaria mensagens.
  Stream<String> get messages => _messages.stream;
  final _messages = StreamController<String>.broadcast();

  StreamSubscription<String>? _linkIncoming;

  /// Apelido do outro lado, quando ele ja informou.
  String? get peerNickname => _peerNickname;
  String? _peerNickname;

  /// Apelido deste aparelho.
  String? get myNickname => _identity?.nickname;

  /// Troca o apelido e avisa o parceiro, se houver conexao.
  Future<void> setMyNickname(String value) async {
    final identity = _identity ??= await DeviceIdentity.load();
    await identity.setNickname(value);
    notifyListeners();
    await _sendNickname();
  }

  ConnectionPhase get phase => _phase;
  ChatLink? get link => _link;
  String? get error => _error;

  /// `true` quando so as configuracoes do sistema resolvem.
  ///
  /// Depois de "nao perguntar novamente" o Android nunca mais mostra o pop-up,
  /// entao insistir no pedido seria um loop invisivel. A UI usa isto para
  /// oferecer um atalho -- abrir as configuracoes sozinho, sem o usuario pedir,
  /// seria jogar ele para fora do app logo na abertura.
  bool get needsAppSettings => _needsAppSettings;
  bool _needsAppSettings = false;

  /// Abre a tela de configuracoes do app.
  Future<void> openAppSettings() => BlePermissions.openSettings();
  bool get isConnected => _link?.isConnected ?? false;
  String? get myNonce => _identity?.nonceHex;

  /// Liga o ciclo: permissoes, managers, advertising e scan.
  Future<void> start() async {
    if (_phase != ConnectionPhase.idle && _phase != ConnectionPhase.failed) {
      return;
    }
    _setPhase(ConnectionPhase.preparing);
    _starting = true;

    try {
      // PASSO 1 -- permissoes antes de qualquer manager existir.
      final granted = await BlePermissions.request();
      _needsAppSettings =
          granted == BleReadiness.permissionPermanentlyDenied;
      if (!granted.isReady) {
        _fail(granted.message);
        return;
      }

      // PASSO 2 -- identidade estavel (nonce persistido).
      _identity ??= await DeviceIdentity.load();

      // PASSO 3 -- so agora os managers nascem, ja autorizados.
      _ensureManagers();

      // PASSO 4 -- garantir o radio ligado ANTES de consultar o plugin.
      //
      // Nao da para perguntar ao plugin se o Bluetooth esta desligado: o
      // `getState()` nativo dele faz
      //
      // ```kotlin
      // val supported = hasSystemFeature(FEATURE_BLUETOOTH_LE)
      //                 && adapter.isMultipleAdvertisementSupported
      // return if (supported) ... else UNSUPPORTED
      // ```
      //
      // e `isMultipleAdvertisementSupported` devolve `false` com o radio
      // desligado. Ou seja, o plugin reporta UNSUPPORTED para um aparelho que
      // suporta BLE perfeitamente -- e o app dizia ao usuario que o celular
      // dele nao servia. Consultamos o adaptador direto para desfazer isso.
      if (!await BluetoothSwitch.isEnabled()) {
        debugPrint('[BlueWhats] radio desligado -- pedindo para ligar');
        if (!await BluetoothSwitch.requestEnable()) {
          _fail(BleReadiness.bluetoothOff.message);
          return;
        }
      }

      // PASSO 5 -- esperar o radio estabilizar; sem isso o servidor GATT
      // ainda nao existe.
      final ready = await BlePermissions.waitPoweredOn(_peripheral!);
      if (!ready) {
        _fail(BlePermissions.stateOf(_peripheral!).message);
        return;
      }

      // PASSO 5 -- publicar o servico ANTES de escutar conexoes. Assinar antes
      // abre uma janela em que um Central conecta e o evento chega sem termos
      // a characteristic registrada: a conexao era descartada e os dois lados
      // ficavam em estados diferentes (um "conectado", o outro procurando).
      await _publishService();
      _listenForCentrals();

      // Um Central pode ja estar conectado no nivel do sistema (o app
      // reiniciou, ou conectou durante a janela acima). Sem isto, o outro lado
      // continuaria se achando conectado enquanto nos procuravamos.
      await _adoptExistingCentral();

      if (_link == null) await _startSearching();
    } catch (e, s) {
      // O detalhe tecnico vai para o log; a tela recebe algo legivel. Despejar
      // a PlatformException crua enchia o banner com stacktrace Java.
      debugPrint('[BlueWhats] start falhou: $e\n$s');
      _fail(
        'Nao foi possivel iniciar o Bluetooth. Toque em Conectar para tentar '
        'de novo.',
      );
    } finally {
      _starting = false;
    }
  }

  /// Para tudo e derruba o link atual.
  Future<void> stop() async {
    _reconnectTimer?.cancel();
    await _stopSearching();
    await _link?.dispose();
    _link = null;
    _setPhase(ConnectionPhase.idle);
  }

  void _ensureManagers() {
    if (_central != null) return;

    final central = _central = CentralManager();
    _peripheral = PeripheralManager();

    // Conexoes de entrada so passam a ser escutadas em [_listenForCentrals],
    // depois do servico publicado.
    _subscriptions.add(central.discovered.listen(_onDiscovered));

    // Um unico listener basta: os dois managers reportam o mesmo radio.
    _subscriptions.add(
      _peripheral!.stateChanged.listen((e) => _onRadioChanged(e.state)),
    );
  }

  /// Reage ao radio Bluetooth sendo desligado ou religado.
  ///
  /// Indispensavel: quando o **proprio** radio cai, nao chega evento de
  /// desconexao nenhum. Sem isto o lado Peripheral continuava exibindo
  /// "Conectado" com um link morto -- observado ao desligar o Bluetooth num
  /// dos aparelhos, enquanto o outro detectava a queda normalmente.
  Future<void> _onRadioChanged(BluetoothLowEnergyState state) async {
    if (_disposed || _phase == ConnectionPhase.idle) return;

    // Enquanto o start() conduz, ele cuida de tudo -- inclusive de esperar o
    // radio. Agir aqui em paralelo faz os dois chamarem startAdvertising e o
    // segundo falha com ADVERTISE_FAILED_ALREADY_STARTED.
    if (_starting && state == BluetoothLowEnergyState.poweredOn) return;

    if (state == BluetoothLowEnergyState.poweredOff) {
      debugPrint('[BlueWhats] radio desligado -- derrubando link');
      // O servidor GATT foi fechado pelo plugin: o registro do servico morreu
      // junto, e advertising/scan pararam sem passar pelos nossos metodos.
      _servicePublished = false;
      _advertising = false;
      _scanning = false;

      final link = _link;
      _link = null;
      await link?.dispose();

      _setPhase(ConnectionPhase.reconnecting);
      // "Reconectando..." sozinho esconderia a causa. Dito assim, o usuario
      // sabe que a acao esta com ele -- e ao religar o app retoma sozinho.
      _error = BleReadiness.bluetoothOff.message;
      if (!_disposed) notifyListeners();
      return;
    }

    // So retomamos por conta propria quando FOMOS derrubados pelo radio.
    // Durante `preparing` quem conduz e o `start()`: reagir aqui publicaria o
    // servico duas vezes, e a segunda troca a instancia de
    // `_messageCharacteristic` -- que e justamente o que faz o `notify` parar
    // de funcionar (ver o comentario naquele campo).
    if (state == BluetoothLowEnergyState.poweredOn &&
        _link == null &&
        _phase == ConnectionPhase.reconnecting) {
      debugPrint('[BlueWhats] radio religado -- republicando servico');
      try {
        await _publishService();
        await _startSearching();
      } catch (e) {
        debugPrint('[BlueWhats] falha ao retomar apos religar: $e');
        _scheduleReconnect();
      }
    }
  }

  /// Passa a escutar Centrals conectando em nos.
  ///
  /// Chamado apenas depois de [_publishService]: antes disso nao temos a
  /// characteristic registrada e a conexao teria de ser descartada.
  void _listenForCentrals() {
    _subscriptions.add(
      _peripheral!.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.connected) _startPeripheralLink(e.central);
      }),
    );
  }

  /// Recupera um Central que ja estivesse conectado no nivel do sistema.
  ///
  /// Acontece quando o app reinicia com a conexao GATT ainda de pe. Sem isto,
  /// o outro lado continuaria se achando conectado enquanto nos procuravamos
  /// -- estados divergentes, e mensagens caindo no vazio.
  Future<void> _adoptExistingCentral() async {
    try {
      final centrals = await _peripheral!.retrieveConnectedCentrals();
      if (centrals.isEmpty) return;
      debugPrint('[BlueWhats] Central ja conectado encontrado, adotando');
      await _startPeripheralLink(centrals.first);
    } catch (e) {
      debugPrint('[BlueWhats] retrieveConnectedCentrals falhou: $e');
    }
  }

  /// Registra o servico GATT que o outro lado vai procurar.
  Future<void> _publishService() async {
    final peripheral = _peripheral!;

    // Limpeza defensiva: numa sessao nova nao ha nada para remover e o plugin
    // lanca IllegalStateException. Nao pode impedir o registro abaixo.
    try {
      await peripheral.removeAllServices();
    } catch (_) {}

    // Guardamos a instancia: e ela, e nenhuma copia, que serve para notificar.
    final characteristic = GATTCharacteristic.mutable(
      uuid: BleContract.messageCharacteristic,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.notify,
      ],
      permissions: [
        GATTCharacteristicPermission.read,
        GATTCharacteristicPermission.write,
      ],
      descriptors: [],
    );

    await peripheral.addService(
      GATTService(
        uuid: BleContract.chatService,
        isPrimary: true,
        includedServices: [],
        characteristics: [characteristic],
      ),
    );

    _messageCharacteristic = characteristic;
    _servicePublished = true;
  }

  Future<void> _startSearching() async {
    final identity = _identity!;

    // Rede de seguranca: qualquer caminho que retome a busca (reconexao por
    // backoff, radio religado) precisa de um servico registrado no servidor
    // GATT atual. Anunciar sem ele faz o outro lado conectar e nao achar nada.
    if (!_servicePublished) await _publishService();

    // O nonce viaja como manufacturer data porque o advertising legado tem
    // apenas 31 bytes: flags (3) + service UUID de 128 bits (18) +
    // manufacturer data (8) = 29. Nao sobra espaco nem para o nome.
    // As flags sao marcadas ANTES do await: marcar depois deixa uma janela em
    // que outra chamada passa pela verificacao e o rádio recebe dois pedidos.
    if (!_advertising) {
      _advertising = true;
      try {
        await _peripheral!.startAdvertising(
          Advertisement(
            serviceUUIDs: [BleContract.chatService],
            manufacturerSpecificData: [
              ManufacturerSpecificData(
                id: BleContract.manufacturerId,
                data: identity.nonce,
              ),
            ],
          ),
        );
      } catch (e) {
        _advertising = false;
        rethrow;
      }
    }

    if (!_scanning) {
      _scanning = true;
      try {
        await _central!.startDiscovery(serviceUUIDs: [BleContract.chatService]);
      } catch (e) {
        _scanning = false;
        rethrow;
      }
    }

    _searchStartedAt ??= DateTime.now();
    _setPhase(ConnectionPhase.searching);
  }

  Future<void> _stopSearching() async {
    // Zera a carencia: a proxima busca comeca contando do zero, senao uma
    // sessao antiga faria estranhos serem aceitos de imediato.
    _searchStartedAt = null;

    if (_scanning) {
      try {
        await _central?.stopDiscovery();
      } catch (_) {}
      _scanning = false;
    }
    if (_advertising) {
      try {
        await _peripheral?.stopAdvertising();
      } catch (_) {}
      _advertising = false;
    }
  }

  /// Alguem que anuncia o nosso Service UUID apareceu no scan.
  Future<void> _onDiscovered(DiscoveredEventArgs e) async {
    if (_link != null || _connecting) return;

    final peerNonce = e.advertisement.manufacturerSpecificData
        .where((m) => m.id == BleContract.manufacturerId)
        .map((m) => m.data)
        .firstOrNull;

    // Sem nonce nao da para desempatar. Pode ser outro app usando o mesmo
    // UUID, ou uma versao antiga do nosso -- ignorar e mais seguro que
    // arriscar os dois lados assumindo o mesmo papel.
    if (peerNonce == null || peerNonce.isEmpty) return;

    final identity = _identity!;

    // Preferir o parceiro conhecido. Sem isto, duas duplas na mesma sala se
    // conectam cruzado -- ganha quem aparecer primeiro no scan.
    final searching = DateTime.now().difference(
      _searchStartedAt ?? DateTime.now(),
    );
    if (!identity.shouldConnectTo(peerNonce, searching: searching)) {
      return;
    }

    if (!identity.shouldBeCentral(peerNonce)) {
      // Nosso nonce e maior: ficamos como Peripheral e esperamos o outro
      // conectar. Continuamos anunciando -- parar aqui nos tornaria invisiveis
      // justamente para quem vai nos procurar.
      return;
    }

    _connecting = true;
    _peerNonce = peerNonce;
    _setPhase(ConnectionPhase.connecting);

    try {
      final link = await CentralChatLink.connect(_central!, e.peripheral);
      await _adoptLink(link);
    } catch (err) {
      debugPrint('[BlueWhats] conexao como Central falhou: $err');
      _connecting = false;
      // Volta a procurar: o parceiro pode reaparecer no proximo anuncio.
      if (_link == null) _setPhase(ConnectionPhase.searching);
    }
  }

  /// Um Central conectou em nos -- somos o lado Peripheral desta sessao.
  Future<void> _startPeripheralLink(Central central) async {
    if (_link != null || _connecting) return;

    final characteristic = _messageCharacteristic;
    if (characteristic == null) {
      // Nao deve mais acontecer: so escutamos conexoes depois de publicar.
      debugPrint('[BlueWhats] conexao recebida antes do servico ser publicado');
      return;
    }

    _connecting = true;
    _setPhase(ConnectionPhase.connecting);

    try {
      final link = PeripheralChatLink(
        _peripheral!,
        central,
        characteristic,
        BleContract.fallbackPayloadSize,
      );

      // O Central precisa assinar antes de conseguirmos notificar. Enviar
      // antes disso perde a mensagem em silencio.
      final subscribed = await link.waitSubscription();
      if (!subscribed) {
        await link.dispose();
        throw StateError('o outro lado nao assinou o canal de mensagens');
      }
      await link.refreshPayloadSize();

      await _adoptLink(link);
    } catch (err) {
      debugPrint('[BlueWhats] conexao como Peripheral falhou: $err');
      _connecting = false;
      if (_link == null) _setPhase(ConnectionPhase.searching);
    }
  }

  /// Assume um link recem-criado como o link ativo.
  Future<void> _adoptLink(ChatLink link) async {
    _link = link;
    _connecting = false;
    _reconnectAttempt = 0;

    // Com o link de pe, anunciar e escanear so gastaria bateria.
    await _stopSearching();

    final peerNonce = _peerNonce;
    if (peerNonce != null) {
      await _identity!.rememberPeer(
        peerNonce: peerNonce,
        address: link.peerId,
      );
    }

    // Cada link e um objeto novo: cancelar a inscricao anterior evita que uma
    // conexao antiga continue empurrando mensagens para a tela.
    await _linkIncoming?.cancel();
    _linkIncoming = link.incoming.listen(_onFrameReceived);

    link.connected.listen((up) {
      if (!up) _onLinkLost();
    });

    // O apelido do parceiro anterior nao vale para o novo.
    _peerNickname = null;
    await _sendNickname();

    debugPrint(
      '[BlueWhats] link estabelecido como ${link.role.name} com ${link.peerId}',
    );
    _setPhase(ConnectionPhase.connected);
  }

  /// Separa apelido de mensagem no que chega.
  void _onFrameReceived(String raw) {
    final frame = ChatFrame.decode(raw);
    if (frame == null) {
      debugPrint('[BlueWhats] quadro desconhecido descartado');
      return;
    }

    switch (frame.type) {
      case ChatFrameType.nickname:
        _peerNickname = frame.text.isEmpty ? null : frame.text;
        debugPrint('[BlueWhats] apelido do parceiro: $_peerNickname');
        if (!_disposed) notifyListeners();
      case ChatFrameType.message:
        if (!_messages.isClosed) _messages.add(frame.text);
    }
  }

  /// Envia o proprio apelido ao parceiro.
  ///
  /// Silencioso quando nao ha apelido ou conexao -- e uma cortesia, nao um
  /// passo obrigatorio: falhar aqui nao pode atrapalhar a conversa.
  Future<void> _sendNickname() async {
    final nickname = _identity?.nickname;
    final link = _link;
    if (nickname == null || link == null || !link.isConnected) return;
    try {
      await link.send(ChatFrame.nickname(nickname).encode());
    } catch (e) {
      debugPrint('[BlueWhats] nao consegui enviar o apelido: $e');
    }
  }

  /// Envia uma mensagem de chat.
  Future<void> sendMessage(String text) async {
    final link = _link;
    if (link == null || !link.isConnected) {
      throw StateError('sem conexao');
    }
    await link.send(ChatFrame.message(text).encode());
  }

  void _onLinkLost() {
    if (_disposed) return;
    _linkIncoming?.cancel();
    _linkIncoming = null;
    _peerNickname = null;
    _link?.dispose();
    _link = null;
    _setPhase(ConnectionPhase.reconnecting);
    _scheduleReconnect();
  }

  /// Reconexao com backoff exponencial, teto de 30s.
  ///
  /// Nao existe atalho confiavel aqui: o endereco BLE do parceiro rotaciona
  /// (Resolvable Private Address) e sem pareamento nao ha como resolve-lo.
  /// Entao a reconexao refaz a descoberta -- que e rapida, porque o scan
  /// filtra pelo nosso Service UUID e o desempate por nonce ja e automatico.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final seconds = (1 << _reconnectAttempt).clamp(1, 30);
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 5);

    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      if (_disposed || _link != null) return;
      try {
        await _startSearching();
      } catch (e) {
        debugPrint('[BlueWhats] falha ao retomar a busca: $e');
        _scheduleReconnect();
      }
    });
  }

  void _setPhase(ConnectionPhase phase) {
    if (_phase == phase) return;
    // Logar as transicoes e o que torna um problema diagnosticavel depois.
    // Sem isto, uma falha silenciosa aparece como um log vazio.
    debugPrint('[BlueWhats] fase: ${_phase.name} -> ${phase.name}');
    _phase = phase;
    if (phase != ConnectionPhase.failed) _error = null;
    if (!_disposed) notifyListeners();
  }

  void _fail(String message) {
    // Escreve _phase direto (e nao via _setPhase) para nao perder a mensagem,
    // que _setPhase limpa. O log fica aqui pelo mesmo motivo -- sem ele, uma
    // falha some do rastro e o log termina no ultimo estado bem-sucedido.
    debugPrint('[BlueWhats] fase: ${_phase.name} -> failed ($message)');
    _error = message;
    _phase = ConnectionPhase.failed;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _linkIncoming?.cancel();
    _messages.close();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _link?.dispose();
    _stopSearching();
    super.dispose();
  }
}

/// Rotulo curto para exibir na UI.
extension ConnectionPhaseLabel on ConnectionPhase {
  String get label => switch (this) {
    ConnectionPhase.idle => 'Parado',
    ConnectionPhase.preparing => 'Preparando...',
    ConnectionPhase.searching => 'Procurando parceiro...',
    ConnectionPhase.connecting => 'Conectando...',
    ConnectionPhase.connected => 'Conectado',
    ConnectionPhase.reconnecting => 'Reconectando...',
    ConnectionPhase.failed => 'Falhou',
  };
}
