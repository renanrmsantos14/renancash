import 'package:budget/struct/mbSync/pareamento.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class MeuBancoParearPage extends StatefulWidget {
  const MeuBancoParearPage({Key? key}) : super(key: key);

  @override
  State<MeuBancoParearPage> createState() => _MeuBancoParearPageState();
}

class _MeuBancoParearPageState extends State<MeuBancoParearPage> {
  final TextEditingController _link = TextEditingController();
  bool _concluido = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _usar(MbPareamento p) async {
    if (_concluido) return;
    _concluido = true;
    final ok = await mbConfirmarEParear(context, p);
    if (!mounted) return;
    if (ok) {
      _link.clear();
      Navigator.of(context).pop();
    } else {
      _concluido = false;
    }
  }

  void _aoDetectar(BarcodeCapture captura) {
    for (final c in captura.barcodes) {
      final raw = c.rawValue;
      final uri = raw == null ? null : Uri.tryParse(raw);
      final p = uri == null ? null : mbLerLinkPareamento(uri);
      if (p != null) {
        _usar(p);
        return;
      }
    }
  }

  void _colar() {
    final uri = Uri.tryParse(_link.text.trim());
    final p = uri == null ? null : mbLerLinkPareamento(uri);
    if (p == null) {
      openSnackbar(SnackbarMessage(title: "Link de pareamento inválido"));
      return;
    }
    _usar(p);
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      dragDownToDismiss: true,
      title: "Parear com QR",
      listWidgets: [
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 20, vertical: 5),
          child: Text(
              "Abra o painel do Meu Banco, crie um token de aparelho e aponte a câmera para o QR.",
              style: EdTexto.corpo(context).copyWith(color: cores(context).mu)),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 20, vertical: 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 320,
              child: MobileScanner(
                onDetect: _aoDetectar,
                errorBuilder: (context, erro, _) => ColoredBox(
                  color: cores(context).surf,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                          "Não foi possível abrir a câmera. Confira a permissão ou cole o link abaixo.",
                          textAlign: TextAlign.center,
                          style: EdTexto.corpo(context)
                              .copyWith(color: cores(context).mu)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 20, vertical: 5),
          child: TextInput(
            labelText: "Colar link",
            controller: _link,
            padding: EdgeInsetsDirectional.zero,
            keyboardType: TextInputType.url,
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 20, vertical: 10),
          child: Button(
            label: "Parear com o link",
            expandedLayout: true,
            onTap: _colar,
          ),
        ),
      ],
    );
  }
}
