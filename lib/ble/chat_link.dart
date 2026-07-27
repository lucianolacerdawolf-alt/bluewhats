import 'dart:async';

/// Qual papel BLE este aparelho assumiu na sessao atual.
///
/// Serve para exibir na UI e para o log. A logica de chat nao deve olhar para
/// isso -- se olhar, a abstracao do [ChatLink] falhou.
enum LinkRole {
  /// Este aparelho iniciou a conexao (tinha o nonce menor).
  central,

  /// Este aparelho estava anunciando e foi conectado pelo outro.
  peripheral,
}

/// Um canal de conversa ja estabelecido com o outro aparelho.
///
/// ## Por que esta interface existe
///
/// No modo de duplo papel, o mesmo celular pode acabar como Central ou como
/// Peripheral, dependendo de quem tinha o nonce menor. E enviar uma mensagem e
/// fisicamente diferente em cada caso:
///
/// | Papel      | Enviar                        | Receber                      |
/// |------------|-------------------------------|------------------------------|
/// | Central    | `writeCharacteristic`         | evento `characteristicNotified` |
/// | Peripheral | `notifyCharacteristic`        | evento `characteristicWriteRequested` |
///
/// Sem esta interface, cada tela de chat precisaria de um `if (souCentral)`
/// em todo lugar. Com ela, a UI chama [send] e escuta [incoming] sem nunca
/// saber de que lado da conexao esta.
///
/// Isso tambem e o que torna barato trocar para a arquitetura de papel fixo
/// caso algum aparelho nao suporte duplo papel: muda o
/// `ConnectionManager`, a UI nao muda nada.
abstract interface class ChatLink {
  /// Qual papel este lado assumiu. Apenas informativo (UI e log).
  LinkRole get role;

  /// Identificador do parceiro, usado para reconexao rapida.
  ///
  /// No Android e derivado do endereco de hardware, entao serve como chave
  /// estavel para guardar em `SharedPreferences` e reconectar direto na
  /// proxima sessao, pulando a descoberta.
  String get peerId;

  /// Mensagens completas recebidas do outro aparelho.
  ///
  /// Ja vem remontadas pelo framing: cada evento e uma mensagem inteira, nunca
  /// um pedaco. Mensagens corrompidas sao descartadas em silencio.
  Stream<String> get incoming;

  /// `false` assim que a conexao cai. Nunca volta a `true` no mesmo link --
  /// reconectar cria um [ChatLink] novo.
  Stream<bool> get connected;

  /// Se o link ainda esta de pe agora.
  bool get isConnected;

  /// Envia [text] ao outro aparelho.
  ///
  /// Cuida sozinho do fatiamento em pacotes que caibam no MTU negociado.
  ///
  /// Lanca [StateError] se o link ja caiu, e pode lancar erros de plataforma
  /// se a conexao cair no meio do envio -- quem chama deve tratar os dois.
  Future<void> send(String text);

  /// Fecha o link e libera os recursos.
  ///
  /// Seguro de chamar mais de uma vez.
  Future<void> dispose();
}
