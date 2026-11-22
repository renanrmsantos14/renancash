import 'package:budget/pages/meuBancoConexoes.dart';
import 'package:budget/pages/meuBancoParear.dart';
import 'package:budget/struct/atualizador.dart';
import 'package:budget/struct/mbSync/pareamento.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/mbSync/espelho.dart' show mbEspelhoDoApp, mbEspelhoLigado, mbEspelhoPermitido;
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/editorial/espelhoEnviar.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/functions.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textInput.dart';
import 'dart:async' show TimeoutException;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';

class MeuBancoPage extends StatefulWidget {
  const MeuBancoPage({
    Key? key,
    this.urlInicial,
    this.pareadoInicial,
    this.contasConectadas,
  }) : super(key: key);

  // Injetáveis para os testes de UI não dependerem de token/URL reais nem de rede.
  final String? urlInicial;
  final bool? pareadoInicial;
  final Widget? contasConectadas;

  @override
  State<MeuBancoPage> createState() => _MeuBancoPageState();
}

class _MeuBancoPageState extends State<MeuBancoPage> {
  final TextEditingController _url =
      TextEditingController(text: meuBancoUrlPadrao);
  final TextEditingController _token = TextEditingController();
  bool _temToken = false;
  bool _atualizando = false;
  bool _procurandoAtualizacao = false;
  String? _msgAtualizacao;
  bool _copiaUnica = false;
  String? _msgCopiaUnica;

  @override
  void initState() {
    super.initState();
    if (widget.urlInicial != null || widget.pareadoInicial != null) {
      _url.text = widget.urlInicial ?? meuBancoUrlPadrao;
      _temToken = widget.pareadoInicial ?? false;
    } else {
      _carregar();
      meuBancoAtualizarRevisar();
    }
  }

  Future<void> _carregar() async {
    final url = await meuBancoLerUrl();
    final token = await meuBancoLerToken();
    if (!mounted) return;
    setState(() {
      _url.text = url;
      _temToken = token != null && token.isNotEmpty;
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _sincronizar() async {
    final url = _url.text.trim().replaceAll(RegExp(r'/+$'), '');
    final segredo = _token.text;
    // Senha, token novo ou endereço diferente é pareamento: mesma validação e confirmação do QR.
    if (segredo.isNotEmpty || url != await meuBancoLerUrl()) {
      if (segredo.trim().isEmpty ||
          !mbOrigemPermitida(url, debug: kDebugMode)) {
        openSnackbar(SnackbarMessage(
            title:
                "Informe um endereço https válido e a senha do painel para parear."));
        return;
      }
      if (mbTokenValido(segredo.trim())) {
        if (!mounted ||
            !await mbConfirmarEParear(
                context, MbPareamento(url, segredo.trim()))) return;
      } else {
        // A senha só sai do aparelho depois que o usuário confirma o endereço.
        if (!mounted || !await mbConfirmarHost(context, url)) return;
        try {
          await mbParear(await mbPedirToken(url, segredo));
        } on String catch (msg) {
          openSnackbar(SnackbarMessage(title: msg));
          return;
        }
      }
      _token.clear();
      await _carregar();
      return;
    }
    await sincronizarMeuBanco();
  }

  Future<void> _atualizarAgora() async {
    setState(() => _atualizando = true);
    final msg = await meuBancoAtualizar();
    if (mounted) setState(() => _atualizando = false);
    openSnackbar(SnackbarMessage(title: msg));
  }

  Future<void> _procurarAtualizacao() async {
    setState(() {
      _procurandoAtualizacao = true;
      _msgAtualizacao = null;
    });
    final msg = await atualizadorVerificarManual(context);
    if (!mounted) return;
    setState(() {
      _procurandoAtualizacao = false;
      _msgAtualizacao = msg.isEmpty ? null : msg;
    });
  }

  // Ação destrutiva: só desconecta depois de confirmar.
  Future<void> _desconectar() async {
    final confirmou = await openPopup<bool>(
      context,
      title: "Desconectar este aparelho?",
      description:
          "O token e o ponto de sincronização saem deste aparelho. As transações já importadas continuam no app.",
      onSubmitLabel: "Desconectar",
      onCancelLabel: "Cancelar",
      onSubmit: () => popRoute(context, true),
      onCancel: () => popRoute(context, false),
    );
    if (confirmou != true) return;
    await meuBancoDesconectar();
    await _carregar();
  }

  Future<bool> _confirmar(String titulo, String descricao, String rotulo,
          IconData icone) async =>
      await openPopup<bool>(
        context,
        title: titulo,
        description: descricao,
        icon: icone,
        onSubmitLabel: rotulo,
        onCancelLabel: "Cancelar",
        onSubmit: () => popRoute(context, true),
        onCancel: () => popRoute(context, false),
      ) ==
      true;

  // Roda uma das ações de cópia única; erro de rede vira mensagem e nada fica pela metade sem aviso.
  Future<void> _copiaUnicaRodar(
      Future<String> Function(MbCliente cliente) acao) async {
    if (_copiaUnica || meuBancoSincronizando.value) return;
    final cliente = await mbClienteConfigurado();
    if (cliente == null) {
      openSnackbar(SnackbarMessage(title: "Este aparelho não está pareado."));
      return;
    }
    setState(() {
      _copiaUnica = true;
      _msgCopiaUnica = null;
    });
    // A flag de sincronização é ligada por quem executa (mbEmRodada), não durante os diálogos de confirmação.
    String msg;
    try {
      msg = await acao(cliente);
    } on MbErroHttp catch (e) {
      msg = e.mensagem;
    } on TimeoutException {
      msg = "Tempo esgotado ao falar com o Meu Banco. Tente de novo.";
    } catch (e) {
      if (kDebugMode) debugPrint("Meu Banco: falha na cópia única: $e");
      msg = "Não foi possível concluir agora. Confira a internet e tente de novo.";
    }
    if (mounted) {
      setState(() {
        _copiaUnica = false;
        _msgCopiaUnica = msg.isEmpty ? null : msg;
      });
    }
    if (msg.isNotEmpty) openSnackbar(SnackbarMessage(title: msg));
  }

  Future<void> _recomecarPelaNuvem() async {
    await _copiaUnicaRodar((cliente) async {
      // Espelho ligado: a nuvem é o espelho, e a troca preserva a aparência deste aparelho.
      if (mbEspelhoLigado()) {
        if (!await _confirmar(
            "Recomeçar pela nuvem?",
            "Os dados deste aparelho serão apagados e baixados de novo do espelho; o que só existe aqui será perdido. A aparência fica como está.",
            "Apagar e baixar",
            Icons.cloud_download_rounded)) return "";
        await mbEmRodada(mbEspelhoDoApp(cliente).substituirPelaNuvem);
        return "Pronto: este aparelho agora tem os dados da nuvem.";
      }
      return mbEspelhoPermitido()
          ? 'Este aparelho ainda não está ligado à nuvem. Use "Enviar dados para a nuvem" no celular antes.'
          : 'O espelho está desligado neste aparelho. Ligue-o antes de recomeçar pela nuvem.';
    });
  }

  Widget _copiaUnicaSecao() => _secao("Cópia única", [
        Text(
            kIsWeb ? "Os dados do celular são os oficiais. Aqui, recomece pela nuvem depois de o celular enviar tudo." : "Os dados do celular são os oficiais. Envie-os para a nuvem uma vez; depois, nos outros aparelhos, recomece pela nuvem.",
            style: EdTexto.corpo(context)),
        const SizedBox(height: 12),
        const EspelhoEnviarItem(),
        const SizedBox(height: 8),
        const EspelhoDiagnostico(),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _copiaUnica ? null : _recomecarPelaNuvem,
          child: _rotuloBotao(_copiaUnica ? "Aguarde…" : "Recomeçar pela nuvem"),
        ),
        if (_msgCopiaUnica != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_msgCopiaUnica!, style: EdTexto.rotulo(context)),
          ),
      ]);

  Widget _secao(String titulo, List<Widget> filhos) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(titulo, style: EdTexto.h2(context)),
            const SizedBox(height: 10),
            ...filhos,
          ],
        ),
      );

  Widget _campos() => Column(children: [
        TextInput(
          labelText: "Endereço do Meu Banco",
          controller: _url,
          padding: EdgeInsetsDirectional.zero,
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 10),
        TextInput(
          labelText: _temToken
              ? "Senha do painel ou token (para trocar)"
              : "Senha do painel ou token",
          controller: _token,
          obscureText: true,
          padding: EdgeInsetsDirectional.zero,
        ),
      ]);

  Widget _parearQr() => OutlinedButton.icon(
        onPressed: () async {
          await pushRoute(context, const MeuBancoParearPage());
          await _carregar();
        },
        icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
        label: _rotuloBotao("Parear com QR"),
      );

  // Pareado: horário da última sincronização, fila e erro, com as duas ações principais.
  // Rótulo numa linha só: os dois botões ficam da mesma altura em tela estreita.
  Widget _rotuloBotao(String texto) => FittedBox(
      fit: BoxFit.scaleDown, child: Text(texto, maxLines: 1, softWrap: false));

  String _versaoInstalada() {
    final v = packageInfoGlobal?.version.trim() ?? '';
    final b = packageInfoGlobal?.buildNumber.trim() ?? '';
    if (v.isEmpty) return '—';
    return b.isEmpty ? v : '$v+$b';
  }

  Widget _status() {
    final e = cores(context);
    final host = Uri.tryParse(_url.text)?.host ?? _url.text;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: e.cartao,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<String?>(
            valueListenable: meuBancoUltimoErro,
            builder: (context, erro, _) => Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: erro == null ? e.pos : e.warn),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text("Pareado · $host",
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context)
                        .copyWith(fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          ValueListenableBuilder<DateTime?>(
            valueListenable: meuBancoUltimaSync,
            builder: (context, ultima, _) => Text(
                ultima == null
                    ? "Ainda não sincronizado nesta sessão"
                    : "Sincronizado ${haQuanto(ultima, DateTime.now())}",
                style: EdTexto.rotulo(context)),
          ),
          ValueListenableBuilder<String?>(
            valueListenable: meuBancoUltimoErro,
            builder: (context, erro, _) => erro == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(erro,
                        style:
                            EdTexto.rotulo(context).copyWith(color: e.warntx)),
                  ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: meuBancoSincronizando,
                builder: (context, sincronizando, _) => FilledButton(
                  onPressed: sincronizando ? null : sincronizarMeuBanco,
                  child: _rotuloBotao(
                      sincronizando ? "Sincronizando…" : "Sincronizar"),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: _atualizando ? null : _atualizarAgora,
                child: _rotuloBotao(
                    _atualizando ? "Atualizando…" : "Atualizar bancos"),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return PageFramework(
      dragDownToDismiss: true,
      horizontalPaddingConstrained: true,
      title: "Meu Banco",
      listWidgets: [
        // Web usa a sessão do painel (cookie): está sempre pareado e não tem pareamento a trocar.
        if (_temToken || kIsWeb) ...[
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
            child: _status(),
          ),
          _secao("Contas conectadas",
              [widget.contasConectadas ?? const ContasConectadas()]),
          _copiaUnicaSecao(),
          if (!kIsWeb)
            _secao("Pareamento", [
              _campos(),
              const SizedBox(height: 10),
              Row(children: [
                if (!kIsWeb) ...[
                  Expanded(child: _parearQr()),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: OutlinedButton(
                    onPressed: _sincronizar,
                    child: _rotuloBotao("Trocar pareamento"),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: e.warntx,
                    minimumSize: const Size(64, 44),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  onPressed: _desconectar,
                  child: const Text("Desconectar este aparelho"),
                ),
              ),
              Text(
                  "Desconectar apaga o token e o ponto de sincronização. As transações já importadas continuam no app.",
                  style: EdTexto.rotulo(context)),
            ]),
        ] else
          _secao("Parear com o Meu Banco", [
            Text(
                "Importa contas, cartões e transações do Meu Banco. O acesso fica guardado de forma segura no aparelho e não entra nos backups.",
                style: EdTexto.corpo(context).copyWith(color: e.mu)),
            const SizedBox(height: 14),
            if (!kIsWeb) ...[_parearQr(), const SizedBox(height: 16)],
            _campos(),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _sincronizar,
              child: const Text("Parear"),
            ),
          ]),
        _secao("App", [
          if (!kIsWeb)
            OutlinedButton(
              onPressed: _procurandoAtualizacao ? null : _procurarAtualizacao,
              child: Text(_procurandoAtualizacao
                  ? "Procurando…"
                  : "Procurar atualização"),
            ),
          if (_msgAtualizacao != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_msgAtualizacao!, style: EdTexto.rotulo(context)),
            ),
          const SizedBox(height: 8),
          Text(
              "Versão instalada: ${_versaoInstalada()}",
              style: EdTexto.mono(context)),
          const SizedBox(height: 32),
        ]),
      ],
    );
  }
}
