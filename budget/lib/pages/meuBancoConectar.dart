import 'package:flutter/material.dart';
import 'package:flutter_pluggy_connect/flutter_pluggy_connect.dart';

class MeuBancoConectarPage extends StatelessWidget {
  final String connectToken;
  final String? itemId;
  final void Function(dynamic data) onSuccess;
  final void Function(dynamic error) onError;
  final Widget? webViewParaTeste;
  const MeuBancoConectarPage({
    Key? key,
    required this.connectToken,
    required this.onSuccess,
    required this.onError,
    this.itemId,
    this.webViewParaTeste,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: webViewParaTeste ??
            PluggyConnect(
              connectToken: connectToken,
              updateItem: itemId,
              language: 'pt',
              onSuccess: onSuccess,
              onError: onError,
              onClose: () => Navigator.of(context).maybePop(),
            ),
      ),
    );
  }
}
