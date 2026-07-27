import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';

/// Resultado da checagem de pre-requisitos antes de ligar o radio.
enum BleReadiness {
  /// Tudo certo: permissoes concedidas e Bluetooth ligado.
  ready,

  /// O usuario negou alguma permissao, mas ainda da para pedir de novo.
  permissionDenied,

  /// O usuario negou marcando "nao perguntar novamente". So resolve indo
  /// nas configuracoes do app -- ver [BlePermissions.openSettings].
  permissionPermanentlyDenied,

  /// Permissoes ok, mas o Bluetooth do aparelho esta desligado.
  bluetoothOff,

  /// O aparelho nao tem hardware BLE, ou a plataforma nao e suportada.
  unsupported,
}

/// Permissoes de Bluetooth.
///
/// ## ORDEM IMPORTA: peca permissao ANTES de criar os managers
///
/// Todos os metodos aqui sao estaticos de proposito, para tornar impossivel
/// escrever a sequencia errada -- eles nao dependem de um manager existir.
///
/// O `PeripheralManager` do plugin abre o servidor GATT dentro do
/// `onStateChanged`, e so quando o estado *muda* para `poweredOn`:
///
/// ```dart
/// void onStateChanged(stateArgs) async {
///   if (_state == state) return;          // so reage a mudanca
///   case BluetoothLowEnergyState.poweredOn: await _openGATTServer();
/// }
/// ```
///
/// E o `getState()` nativo devolve `UNAUTHORIZED` enquanto BLUETOOTH_ADVERTISE
/// e BLUETOOTH_CONNECT nao estiverem concedidas.
///
/// Se o manager for criado antes das permissoes, ele nasce em `unauthorized`,
/// nunca abre o servidor, e -- como o radio nao muda de estado depois -- o
/// `onStateChanged` jamais dispara de novo. Toda operacao de GATT passa entao a
/// falhar com `IllegalStateException` vindo de `mServer ?: throw`.
///
/// Isso foi diagnosticado em aparelho real (Xiaomi, Android 16): o advertising
/// falhava sem o hardware nunca ter sido consultado.
///
/// ## Por que NAO usamos o `authorize()` do plugin
///
/// Ele pede apenas as permissoes do papel Central (SCAN e CONNECT) --
/// BLUETOOTH_ADVERTISE nunca e solicitada, e sem ela o advertising falha em
/// silencio. Confirmado por `dumpsys package`, onde ADVERTISE aparecia
/// `granted=false` e sem a flag `USER_SET`, provando que nunca foi pedida.
/// Aquele `authorize()` tambem travou sem completar o Future no mesmo aparelho.
class BlePermissions {
  BlePermissions._();

  /// Permissoes exigidas no Android 12+ (API 31+).
  ///
  /// ADVERTISE e obrigatoria no modo de duplo papel: sem ela o advertising
  /// falha em silencio -- nao lanca excecao, so nunca aparece para ninguem.
  static const _required = <Permission>[
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.bluetoothAdvertise,
  ];

  /// Pede as permissoes. Chame ANTES de construir qualquer manager.
  ///
  /// Devolve [BleReadiness.ready] quando todas foram concedidas -- o estado do
  /// radio ainda precisa ser conferido depois, com [stateOf].
  ///
  /// Seguro de chamar varias vezes: se ja foram concedidas, nao ha pop-up.
  ///
  /// O [timeout] evita travar a UI se a plataforma nunca responder.
  static Future<BleReadiness> request({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final Map<Permission, PermissionStatus> results;
    try {
      results = await _required.request().timeout(timeout);
    } on TimeoutException {
      return BleReadiness.permissionDenied;
    }

    if (results.values.any((s) => s.isPermanentlyDenied)) {
      return BleReadiness.permissionPermanentlyDenied;
    }
    if (results.values.any((s) => !s.isGranted)) {
      return BleReadiness.permissionDenied;
    }
    return BleReadiness.ready;
  }

  /// Traduz o estado do radio de um manager ja criado.
  static BleReadiness stateOf(BluetoothLowEnergyManager manager) =>
      switch (manager.state) {
        BluetoothLowEnergyState.poweredOn => BleReadiness.ready,
        BluetoothLowEnergyState.poweredOff => BleReadiness.bluetoothOff,
        BluetoothLowEnergyState.unsupported => BleReadiness.unsupported,
        BluetoothLowEnergyState.unauthorized => BleReadiness.permissionDenied,
        BluetoothLowEnergyState.unknown => BleReadiness.permissionDenied,
      };

  /// Espera o manager chegar em `poweredOn`.
  ///
  /// Necessario porque o plugin abre o servidor GATT de forma assincrona, ao
  /// reagir a mudanca de estado. Chamar `addService` antes disso estoura em
  /// `IllegalStateException`.
  static Future<bool> waitPoweredOn(
    BluetoothLowEnergyManager manager, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (manager.state == BluetoothLowEnergyState.poweredOn) return true;
    try {
      await manager.stateChanged
          .firstWhere((e) => e.state == BluetoothLowEnergyState.poweredOn)
          .timeout(timeout);
      return true;
    } on TimeoutException {
      return manager.state == BluetoothLowEnergyState.poweredOn;
    }
  }

  /// Abre a tela de configuracoes do app.
  ///
  /// Unica saida quando o resultado e [BleReadiness.permissionPermanentlyDenied]:
  /// a partir dai o Android nao mostra mais o pop-up de permissao.
  static Future<bool> openSettings() => openAppSettings();

  /// Detalha o estado de cada permissao, para log e diagnostico.
  static Future<Map<String, String>> diagnose() async {
    final entries = await Future.wait(
      _required.map(
        (p) async =>
            MapEntry(p.toString().split('.').last, (await p.status).name),
      ),
    );
    return Map.fromEntries(entries);
  }
}

/// Mensagem pronta para exibir ao usuario, explicando o que fazer.
extension BleReadinessMessage on BleReadiness {
  bool get isReady => this == BleReadiness.ready;

  String get message => switch (this) {
    BleReadiness.ready => 'Pronto para conversar.',
    // Sem "toque aqui": o banner nao e clicavel, quem tenta de novo e o botao
    // Conectar. Prometer uma acao que nao existe e pior que nao explicar.
    BleReadiness.permissionDenied =>
      'O app precisa da permissao "Dispositivos por perto" para encontrar o '
          'outro celular. Use Conectar para pedir de novo.',
    BleReadiness.permissionPermanentlyDenied =>
      'As permissoes de Bluetooth foram bloqueadas. Abra as configuracoes do '
          'app e libere Dispositivos por perto.',
    BleReadiness.bluetoothOff =>
      'O Bluetooth esta desligado. Ligue para continuar.',
    // Com o radio ja confirmado ligado, este estado significa que o aparelho
    // nao consegue ANUNCIAR (papel Peripheral) -- e nao que lhe falte BLE.
    // Dizer "nao tem suporte a BLE" seria mentira: o proprio plugin reporta
    // este estado com o Bluetooth apenas desligado.
    BleReadiness.unsupported =>
      'Este aparelho nao consegue se anunciar por Bluetooth, entao nao pode '
          'ser encontrado pelo outro celular.',
  };
}
