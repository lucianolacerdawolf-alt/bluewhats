import 'package:flutter/material.dart';

import 'ui/chat_screen.dart';

void main() {
  runApp(const BlueWhatsApp());
}

class BlueWhatsApp extends StatelessWidget {
  const BlueWhatsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BlueWhats',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const ChatScreen(),
    );
  }
}
