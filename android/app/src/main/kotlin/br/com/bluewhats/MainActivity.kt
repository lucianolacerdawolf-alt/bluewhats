package br.com.bluewhats

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Expoe ao Dart o pedido nativo para ligar o Bluetooth.
 *
 * O plugin `bluetooth_low_energy` sabe dizer que o radio esta desligado, mas
 * nao sabe pedir para liga-lo. Sem isto o app so conseguiria exibir um aviso e
 * mandar o usuario procurar o interruptor sozinho -- num app cujo objetivo e
 * justamente dispensar configuracao manual.
 *
 * `ACTION_REQUEST_ENABLE` mostra o dialogo do proprio sistema ("permitir que o
 * app ative o Bluetooth?"), sem exigir dependencia extra.
 */
class MainActivity : FlutterActivity() {

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(adapter()?.isEnabled ?: false)
                "requestEnable" -> requestEnable(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun adapter(): BluetoothAdapter? =
        (getSystemService(BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun requestEnable(result: MethodChannel.Result) {
        val adapter = adapter()
        if (adapter == null) {
            result.success(false)
            return
        }
        if (adapter.isEnabled) {
            result.success(true)
            return
        }

        // Um segundo pedido enquanto o dialogo esta aberto responderia duas
        // vezes o mesmo Result, o que derruba o engine do Flutter.
        if (pendingResult != null) {
            result.success(false)
            return
        }

        pendingResult = result
        try {
            startActivityForResult(
                Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                REQUEST_ENABLE_BT,
            )
        } catch (e: Throwable) {
            pendingResult = null
            result.error("REQUEST_ENABLE_FAILED", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_ENABLE_BT) return

        val result = pendingResult ?: return
        pendingResult = null
        result.success(resultCode == Activity.RESULT_OK)
    }

    companion object {
        private const val CHANNEL = "bluewhats/bluetooth"
        private const val REQUEST_ENABLE_BT = 4821
    }
}
