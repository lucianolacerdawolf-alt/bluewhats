import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Pede ao sistema para ligar o Bluetooth.
///
/// O `bluetooth_low_energy` sabe informar que o radio esta desligado, mas nao
/// oferece como liga-lo. Sem isto o app apenas exibiria um aviso e deixaria o
/// usuario procurar o interruptor -- atrito demais para um app que existe para
/// dispensar configuracao manual.
///
/// A implementacao nativa esta em `MainActivity.kt` e usa
/// `BluetoothAdapter.ACTION_REQUEST_ENABLE`, que mostra o dialogo do proprio
/// Android. Nada e ligado pelas nossas costas: quem decide e o usuario.
class BluetoothSwitch {
  BluetoothSwitch._();

  static const _channel = MethodChannel('bluewhats/bluetooth');

  /// Se o radio esta ligado agora.
  static Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } on MissingPluginException {
      // Plataforma sem a implementacao nativa (testes, desktop).
      return false;
    } on PlatformException catch (e) {
      debugPrint('[BlueWhats] isEnabled falhou: $e');
      return false;
    }
  }

  /// Mostra o dialogo do sistema pedindo para ligar o Bluetooth.
  ///
  /// Devolve `true` se o radio ficou ligado -- seja porque ja estava, seja
  /// porque o usuario aceitou. `false` se ele recusou ou se a plataforma nao
  /// suporta o pedido.
  static Future<bool> requestEnable() async {
    try {
      return await _channel.invokeMethod<bool>('requestEnable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[BlueWhats] requestEnable falhou: $e');
      return false;
    }
  }
}
