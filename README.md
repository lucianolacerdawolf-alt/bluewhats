# BlueWhats

Chat ponto a ponto entre dois celulares por **Bluetooth Low Energy** — sem internet, sem servidor e **sem parear** nas configurações do Android.

Os aparelhos se encontram sozinhos ao abrir o app, decidem entre si quem inicia a conexão e conversam por um canal GATT direto.

## Como funciona

```
App A                                          App B
  │                                              │
  ├─ anuncia (Service UUID + nonce) ─────────────┤ anuncia
  ├─ escaneia ───────────────────────────────────┤ escaneia
  │                                              │
  │  ambos se veem → compara nonces              │
  │  nonce menor  → vira Central e conecta       │
  │  nonce maior  → vira Peripheral e espera     │
  │                                              │
  └──────── link GATT aberto, bidirecional ──────┘
```

Os dois aparelhos rodam **advertising e scan ao mesmo tempo** (duplo papel). O desempate por *nonce* garante papéis opostos sem que precisem combinar nada — a comparação byte a byte dá o mesmo veredito nos dois lados.

Depois de conectados, a assimetria do BLE fica escondida atrás da interface `ChatLink`:

| Papel | Enviar | Receber |
|---|---|---|
| Central | `writeCharacteristic` | evento `characteristicNotified` |
| Peripheral | `notifyCharacteristic` | evento `characteristicWriteRequested` |

A UI chama `send()` e escuta `incoming` — nunca precisa saber de que lado está.

## Estrutura

```
lib/
  core/
    ble_constants.dart      contrato BLE (Service/Characteristic UUID)
    permissions.dart        permissões de runtime + estado do rádio
    bluetooth_switch.dart   pede para ligar o Bluetooth (canal nativo)
  ble/
    chat_link.dart          interface que esconde o papel BLE
    central_link.dart       lado que iniciou a conexão
    peripheral_link.dart    lado que estava anunciando
    connection_manager.dart orquestra duplo papel, desempate e reconexão
    device_identity.dart    nonce persistente, apelido, parceiro conhecido
    framing.dart            fatiamento e remontagem de mensagens
    chat_protocol.dart      distingue mensagem de apelido no mesmo canal
  data/
    message.dart            modelo
    message_repository.dart histórico local (sqflite)
  ui/
    chat_screen.dart        tela única
```

## Rodando

Requer **dois aparelhos Android físicos** — emulador não tem acesso ao rádio BLE.

```bash
flutter pub get
flutter run
```

`minSdk` é 24 (exigência do `bluetooth_low_energy`).

## Testes

```bash
flutter test
```

49 testes cobrindo framing (incluindo emoji e acentos partidos entre pacotes), desempate de papéis, preferência pelo parceiro conhecido, protocolo de quadros e a tela.

## Notas de implementação

Coisas que só apareceram rodando em hardware real e que valem registro:

**A identidade da characteristic é o `hashCode` do objeto Dart.** O plugin resolve a characteristic por `hashCode`, não por UUID. Criar um `GATTCharacteristic` novo na hora de notificar faz `notifyCharacteristic` **retornar em silêncio** — sem erro, sem entrega. É obrigatório reusar a mesma instância passada ao `addService`.

**Ordem de inicialização.** Permissões → managers → `poweredOn` → publicar serviço → anunciar. O `PeripheralManager` lê as permissões no construtor; se nascer antes delas, fica preso em `unauthorized` e o servidor GATT nunca abre.

**`BLUETOOTH_ADVERTISE` precisa ser pedida explicitamente.** O `authorize()` do plugin solicita apenas as permissões do papel Central.

**O plugin confunde "Bluetooth desligado" com "sem suporte a BLE"**, porque `isMultipleAdvertisementSupported` retorna `false` com o rádio desligado. O app consulta o adaptador direto antes de confiar nesse estado.

**O endereço BLE rotaciona.** O Android usa *Resolvable Private Address*, e sem pareamento não há IRK para resolvê-lo. Por isso a identidade estável é um nonce gerado pelo app, não o endereço.

**Flag de guarda marcada depois de um `await` não protege nada.** A janela entre verificar e marcar é onde a segunda chamada entra — causou `ADVERTISE_FAILED_ALREADY_STARTED` mais de uma vez.

**O apelido não vai no advertising.** O pacote primário tem 31 bytes e já usa 29. O plugin só conseguiria anunciá-lo chamando `adapter.setName()`, que renomearia o Bluetooth do aparelho inteiro. Ele é trocado por GATT depois da conexão.

## Limitações conhecidas

- Apenas Android. iOS não foi testado.
- Dois participantes por conversa.
- O apelido não aparece antes de conectar (ver acima).
- Sem criptografia de aplicação — o link BLE não é pareado, então não há vínculo criptográfico entre os aparelhos.
