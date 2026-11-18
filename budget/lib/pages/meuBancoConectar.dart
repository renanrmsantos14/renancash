import 'package:budget/struct/editorial.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pluggy_connect/flutter_pluggy_connect.dart';

class MeuBancoConectarPage extends StatefulWidget {
  final String connectToken;
  final String? itemId;
  final void Function(dynamic data) onSuccess;
  final void Function(dynamic error) onError;
  final Widget? webViewParaTeste;
  final String? erroInicial;
  const MeuBancoConectarPage({
    Key? key,
    required this.connectToken,
    required this.onSuccess,
    required this.onError,
    this.itemId,
    this.webViewParaTeste,
    this.erroInicial,
  }) : super(key: key);

  @override
  State<MeuBancoConectarPage> createState() => _MeuBancoConectarPageState();
}

class _MeuBancoConectarPageState extends State<MeuBancoConectarPage> {
  String? _erro;
  int _tentativa = 0;

  @override
  void initState() {
    super.initState();
    _erro = widget.erroInicial;
  }

  void _tratarErro(dynamic error) {
    widget.onError(error);
    if (!mounted) return;
    final texto = '$error'.trim();
    setState(() {
      _erro = texto.isEmpty
          ? 'Não foi possível abrir o Pluggy Connect.'
          : (texto.length > 200 ? texto.substring(0, 200) : texto);
    });
  }

  void _tentarDeNovo() {
    setState(() {
      _erro = null;
      _tentativa++;
    });
  }

  Widget _carregando(BuildContext context) {
    final e = cores(context);
    return ColoredBox(
      color: e.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: e.tx,
              ),
            ),
            const SizedBox(height: 12),
            Text('Abrindo conexão segura…', style: EdTexto.rotulo(context)),
          ],
        ),
      ),
    );
  }

  Widget _cartaoErro(BuildContext context, String mensagem) {
    final e = cores(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: e.surf,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: e.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Não foi possível conectar o banco',
                  style: EdTexto.corpo(context)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  mensagem,
                  style: EdTexto.rotulo(context).copyWith(color: e.warntx),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(64, 44),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Voltar'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: e.tx,
                        foregroundColor: e.bg,
                        minimumSize: const Size(64, 44),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      onPressed: _tentarDeNovo,
                      child: const Text('Tentar de novo'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final titulo =
        widget.itemId != null ? 'Reconectar banco' : 'Conectar banco';
    final erro = _erro;
    final Widget conteudo;
    if (erro != null) {
      conteudo = _cartaoErro(context, erro);
    } else if (widget.webViewParaTeste != null) {
      conteudo = widget.webViewParaTeste!;
    } else {
      conteudo = Stack(
        fit: StackFit.expand,
        children: [
          _carregando(context),
          PluggyConnect(
            key: ValueKey(_tentativa),
            connectToken: widget.connectToken,
            updateItem: widget.itemId,
            language: 'pt',
            onSuccess: widget.onSuccess,
            onError: _tratarErro,
            onClose: () => Navigator.of(context).maybePop(),
          ),
        ],
      );
    }
    return Scaffold(
      backgroundColor: e.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 56,
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: e.bg,
                border: Border(bottom: BorderSide(color: e.line)),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Voltar',
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    icon: Icon(Icons.arrow_back_rounded,
                        size: 20, color: e.tx),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      titulo,
                      overflow: TextOverflow.ellipsis,
                      style: EdTexto.corpo(context).copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: conteudo),
          ],
        ),
      ),
    );
  }
}
