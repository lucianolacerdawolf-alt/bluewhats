import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ble/connection_manager.dart';
import '../ble/device_identity.dart';
import '../data/message.dart';
import '../data/message_repository.dart';

/// Tela principal: status da conexao em cima, conversa embaixo.
///
/// A UI nunca consulta o papel BLE para decidir como enviar -- ela chama
/// `link.send()` e pronto. Toda a assimetria entre Central e Peripheral fica
/// escondida atras do [ChatLink].
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _manager = ConnectionManager();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <Message>[];

  MessageRepository? _repository;
  StreamSubscription<String>? _incoming;
  bool _sending = false;

  /// `true` quando o banco nao abriu. A conversa continua funcionando em
  /// memoria, mas o usuario precisa saber que nada esta sendo salvo.
  bool _historyUnavailable = false;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManagerChanged);
    // O manager entrega mensagens ja separadas dos quadros de apelido, e o
    // stream sobrevive a reconexoes -- por isso uma inscricao so, aqui.
    _incoming = _manager.messages.listen(_onMessageReceived);
    _bootstrap();
  }

  /// Carrega o historico e ja sai procurando o parceiro.
  ///
  /// Conectar sozinho e o ponto do app: exigir um toque em "Conectar" seria
  /// atrito num fluxo que existe justamente para dispensar configuracao. O
  /// botao continua na barra, mas so para tentar de novo apos uma falha.
  Future<void> _bootstrap() async {
    try {
      final repository = await MessageRepository.open();
      final history = await repository.loadAll();
      if (!mounted) return;
      setState(() {
        _repository = repository;
        _messages
          ..clear()
          ..addAll(history);
      });
      _scrollToEnd();
    } catch (e, s) {
      // Falhar aqui nao pode derrubar a tela: o chat e a funcao principal, o
      // historico e conveniencia. Sem o banco a conversa roda em memoria e o
      // usuario e avisado -- perder mensagens em silencio seria pior.
      debugPrint('[BlueWhats] historico indisponivel: $e\n$s');
      if (mounted) setState(() => _historyUnavailable = true);
    }

    // Depois do historico para a tela ja abrir com a conversa no lugar; a
    // permissao aparece por cima, sem esconder o que o usuario veio ver.
    if (mounted) await _manager.start();
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _onMessageReceived(String text) async {
    final message = Message(text: text, mine: false, sentAt: DateTime.now());
    final saved = await _repository?.save(message) ?? message;
    if (!mounted) return;
    setState(() => _messages.add(saved));
    _scrollToEnd();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || !_manager.isConnected || _sending) return;

    setState(() => _sending = true);
    try {
      await _manager.sendMessage(text);

      final message = Message(text: text, mine: true, sentAt: DateTime.now());
      final saved = await _repository?.save(message) ?? message;
      if (!mounted) return;
      setState(() {
        _messages.add(saved);
        _input.clear();
      });
      _scrollToEnd();
    } catch (e) {
      // Nao gravamos a mensagem que falhou: o historico deve refletir o que
      // realmente saiu do aparelho, nao o que tentamos enviar.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nao foi possivel enviar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Pede o apelido e avisa o parceiro se ja houver conexao.
  Future<void> _editNickname() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => _NicknameDialog(initial: _manager.myNickname ?? ''),
    );
    if (chosen != null) await _manager.setMyNickname(chosen);
  }

  /// Gera e envia uma mensagem longa o bastante para forcar o fatiamento.
  ///
  /// Existe porque "chegou inteira" nao prova o framing: com MTU de 517 o
  /// payload util e de 512 bytes, entao qualquer mensagem de chat comum cabe
  /// em um pacote so e o codigo de chunking nunca roda.
  ///
  /// Os marcadores `seg001..seg090` entre `INI.` e `.FIM` tornam qualquer
  /// truncamento, perda ou reordenacao imediatamente visivel na tela.
  Future<void> _sendFramingProbe() async {
    final segments = List.generate(
      90,
      (i) => 'seg${(i + 1).toString().padLeft(3, '0')}',
    );
    _input.text = 'INI.${segments.join('.')}.FIM';
    await _send();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _incoming?.cancel();
    _manager.removeListener(_onManagerChanged);
    _manager.dispose();
    _repository?.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = _manager.phase;
    final connected = _manager.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BlueWhats'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            onPressed: _editNickname,
            icon: const Icon(Icons.badge_outlined),
            tooltip: 'Seu apelido',
          ),
          // Only in debug builds: nao vai para uma versao de release.
          if (kDebugMode)
            IconButton(
              onPressed: connected && !_sending ? _sendFramingProbe : null,
              icon: const Icon(Icons.science_outlined),
              tooltip: 'Enviar mensagem longa (teste de framing)',
            ),
          if (phase == ConnectionPhase.idle || phase == ConnectionPhase.failed)
            TextButton.icon(
              onPressed: _manager.start,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Conectar'),
            )
          else
            IconButton(
              onPressed: _manager.stop,
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: 'Parar',
            ),
        ],
      ),
      body: Column(
        children: [
          _StatusBanner(
            phase: phase,
            error: _manager.error,
            peerNickname: _manager.peerNickname,
            myNickname: _manager.myNickname,
            // A mensagem manda abrir as configuracoes; sem este atalho ela
            // pediria algo sem oferecer como fazer.
            onOpenSettings:
                _manager.needsAppSettings ? _manager.openAppSettings : null,
          ),
          if (_historyUnavailable)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Text(
                'Historico indisponivel - as mensagens desta sessao nao serao '
                'salvas.',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _Bubble(
                      message: _messages[i],
                      peerNickname: _manager.peerNickname,
                      myNickname: _manager.myNickname,
                    ),
                  ),
          ),
          _Composer(
            controller: _input,
            enabled: connected && !_sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

/// Dialogo de escolha do apelido.
///
/// E um StatefulWidget de proposito, e nao um `AlertDialog` montado direto no
/// `showDialog`: o `TextEditingController` precisa viver enquanto o campo
/// existir. Cria-lo fora e descarta-lo logo apos o `showDialog` retornar
/// derruba o app com
///
/// ```
/// 'package:flutter/src/widgets/framework.dart': Failed assertion:
/// '_dependents.isEmpty': is not true.
/// ```
///
/// porque o `showDialog` completa quando a rota e removida, mas a **animacao
/// de saida ainda esta rodando** e o `TextField` continua montado usando o
/// controller. Quem cria o controller tem que ser quem o descarta.
class _NicknameDialog extends StatefulWidget {
  const _NicknameDialog({required this.initial});

  final String initial;

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Seu apelido'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: DeviceIdentity.nicknameMaxLength,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          hintText: 'Como o outro te ve',
          // Deixa claro que isto nao mexe no aparelho -- e a duvida natural de
          // quem ja viu apps renomearem o Bluetooth do celular.
          helperText: 'So dentro do BlueWhats. Nao muda o nome do seu celular.',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.phase,
    required this.error,
    required this.peerNickname,
    required this.myNickname,
    this.onOpenSettings,
  });

  final ConnectionPhase phase;
  final String? error;
  final String? peerNickname;
  final String? myNickname;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (phase) {
      ConnectionPhase.connected => (Colors.green.shade700, Icons.link),
      ConnectionPhase.failed => (scheme.error, Icons.error_outline),
      ConnectionPhase.idle => (scheme.outline, Icons.bluetooth_disabled),
      _ => (scheme.primary, Icons.bluetooth_searching),
    };

    // Conectado, o titulo diz COM QUEM -- o papel BLE e o nonce sao detalhe
    // de implementacao, nao informacao util para quem esta conversando.
    final title = phase == ConnectionPhase.connected && peerNickname != null
        ? 'Conectado com $peerNickname'
        : phase.label;

    final subtitle = error ??
        (phase == ConnectionPhase.connected && peerNickname == null
            ? 'O outro lado ainda nao escolheu um apelido'
            : myNickname == null
                ? 'Toque no cracha para escolher seu apelido'
                : 'Voce: $myNickname');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontWeight: FontWeight.w600, color: color),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (onOpenSettings != null)
            TextButton(
              onPressed: onOpenSettings,
              child: const Text('Configuracoes'),
            )
          else if (phase == ConnectionPhase.searching ||
              phase == ConnectionPhase.connecting ||
              phase == ConnectionPhase.reconnecting)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              // O app conecta sozinho ao abrir: mandar "tocar em Conectar"
              // aqui contradiria o proprio comportamento.
              'Abra o app nos dois celulares.\n'
              'Eles se acham sozinhos, sem parear.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.peerNickname,
    required this.myNickname,
  });

  final Message message;
  final String? peerNickname;
  final String? myNickname;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = message.sentAt;
    final stamp = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';

    // Sem apelido nao mostramos rotulo nenhum: o lado do balao ja diz quem
    // falou, e um "Desconhecido" generico so poluiria a conversa.
    final author = message.mine ? myNickname : peerNickname;

    return Align(
      alignment: message.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: message.mine
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: message.mine ? const Radius.circular(4) : null,
            bottomLeft: message.mine ? null : const Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (author != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  author,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 2),
            ],
            Text(message.text),
            const SizedBox(height: 2),
            Text(
              stamp,
              style: TextStyle(fontSize: 10, color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                maxLines: 4,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: enabled ? 'Mensagem' : 'Sem conexao',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
