import 'package:blue_whats/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A tela agora tenta conectar sozinha ao abrir. Em ambiente de teste nao ha
  // plugin de permissao respondendo, entao o pedido fica pendente ate o
  // timeout de 60s de BlePermissions.request(). [drain] avanca o relogio
  // falso para esse timer disparar -- sem isso o flutter_test acusa
  // "pending timer" e o teste falha mesmo com as asercoes corretas.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 61));
  }

  testWidgets('tela de chat monta com os controles esperados', (tester) async {
    await tester.pumpWidget(const BlueWhatsApp());

    expect(find.text('BlueWhats'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await drain(tester);
  });

  testWidgets('campo de mensagem fica desabilitado sem conexao', (
    tester,
  ) async {
    await tester.pumpWidget(const BlueWhatsApp());

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    expect(find.text('Sem conexao'), findsOneWidget);

    await drain(tester);
  });

  testWidgets('instrucao nao manda tocar em Conectar (o app conecta sozinho)', (
    tester,
  ) async {
    await tester.pumpWidget(const BlueWhatsApp());
    expect(find.textContaining('dois celulares'), findsOneWidget);
    expect(find.textContaining('Toque em Conectar'), findsNothing);

    await drain(tester);
  });

  group('dialogo de apelido', () {
    // Estes testes existem por causa de um crash real: o controller era criado
    // fora do dialogo e descartado logo apos o showDialog retornar, enquanto a
    // animacao de saida ainda mantinha o TextField montado. O app quebrava com
    // "'_dependents.isEmpty': is not true". Fechar o dialogo aqui percorre
    // exatamente esse caminho.

    testWidgets('abre e fecha no Cancelar sem quebrar', (tester) async {
      await tester.pumpWidget(const BlueWhatsApp());

      await tester.tap(find.byIcon(Icons.badge_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Seu apelido'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(find.text('Seu apelido'), findsNothing);
      expect(tester.takeException(), isNull);

      await drain(tester);
    });

    testWidgets('abre e fecha no Salvar sem quebrar', (tester) async {
      await tester.pumpWidget(const BlueWhatsApp());

      await tester.tap(find.byIcon(Icons.badge_outlined));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Luciano');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();

      expect(find.text('Seu apelido'), findsNothing);
      expect(tester.takeException(), isNull);

      await drain(tester);
    });

    testWidgets('avisa que nao muda o nome do celular', (tester) async {
      // A duvida natural de quem ja viu apps renomearem o Bluetooth.
      await tester.pumpWidget(const BlueWhatsApp());
      await tester.tap(find.byIcon(Icons.badge_outlined));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Nao muda o nome do seu celular'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      await drain(tester);
    });
  });

  testWidgets('tenta conectar sozinho ao abrir, sem esperar toque', (
    tester,
  ) async {
    // O ponto do app e nao exigir configuracao: abrir ja procura o parceiro.
    await tester.pumpWidget(const BlueWhatsApp());
    expect(find.text('Parado'), findsOneWidget, reason: 'estado inicial');

    // Deixa o bootstrap (historico + start) rodar.
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Parado'),
      findsNothing,
      reason: 'deveria ter saido de Parado sozinho',
    );

    await drain(tester);
  });
}
