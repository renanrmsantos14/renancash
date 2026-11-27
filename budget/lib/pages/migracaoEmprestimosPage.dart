import 'package:budget/functions.dart' show pushRoute;
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl, diaMes;
import 'package:budget/struct/mbSync/migracaoEmprestimos.dart';
import 'package:budget/struct/meuBancoSync.dart' show sincronizarMeuBanco;
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart' show snackbarKey;
import 'package:flutter/material.dart';

// "Empréstimos antigos": traz os empréstimos do modelo anterior (objetivos do Cashew) para a tela Empréstimos.
// Nada é gravado antes da confirmação; cada empréstimo mostra o que muda, cada centavo de diferença tem motivo,
// e dá para desfazer por empréstimo. O histórico antigo nunca é apagado.

String _r(int centavos) => brl(centavos / 100);

String _data(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  return d == null ? 'sem data' : diaMes(d);
}

void abrirMigracaoEmprestimos(BuildContext context) => pushRoute(context, const MigracaoEmprestimosPage());

class MigracaoEmprestimosPage extends StatefulWidget {
  // `cliente` existe para os testes e prints exercitarem a tela sem rede.
  const MigracaoEmprestimosPage({super.key, this.cliente, this.previaInicial});
  final MbCliente? cliente;
  final MbMigPrevia? previaInicial;

  @override
  State<MigracaoEmprestimosPage> createState() => _MigracaoEmprestimosPageState();
}

class _MigracaoEmprestimosPageState extends State<MigracaoEmprestimosPage> {
  MbMigPrevia? _previa;
  String? _erro;
  bool _ocupado = false;
  final _ajustar = <String>{};
  final _pessoas = <String, String>{};
  final _escolhidos = <String>{};
  bool _recomendacaoAplicada = false;

  @override
  void initState() {
    super.initState();
    _previa = widget.previaInicial;
    if (_previa == null) _carregar();
  }

  Future<MbCliente?> _cliente() async => widget.cliente ?? await mbClienteConfigurado();

  Future<void> _carregar({bool primeira = true}) async {
    setState(() {
      _ocupado = true;
      _erro = null;
    });
    try {
      final c = await _cliente();
      if (c == null) throw 'Conecte o Meu Banco para ver os empréstimos antigos.';
      var p = await c.emprestimosPrevia(ajustar: _ajustar);
      if (primeira && !_recomendacaoAplicada) {
        // Já liga o ajuste de datas onde ele aproxima o saldo novo do antigo: a pessoa vê os dois números e pode desligar.
        _recomendacaoAplicada = true;
        final recomendados = [for (final i in p.migraveis) if (i.ajusteRecomendado) i.objetivo];
        if (recomendados.isNotEmpty) {
          _ajustar.addAll(recomendados);
          p = await c.emprestimosPrevia(ajustar: _ajustar);
        }
      }
      if (!mounted) return;
      setState(() {
        _previa = p;
        _escolhidos.removeWhere((o) => !p.migraveis.any((i) => i.objetivo == o));
      });
    } catch (e) {
      if (mounted) setState(() => _erro = mbErroDeRede(e) ?? '$e');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _alternarAjuste(MbMigItem i, bool ligar) async {
    ligar ? _ajustar.add(i.objetivo) : _ajustar.remove(i.objetivo);
    await _carregar(primeira: false);
  }

  String _pessoaDe(MbMigItem i) => _pessoas[i.objetivo] ?? i.pessoa ?? '';

  Future<void> _editarPessoa(MbMigItem i) async {
    final c = TextEditingController(text: _pessoaDe(i));
    final nome = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quem recebeu o empréstimo?'),
        content: TextField(key: const Key('campo_pessoa'), controller: c, autofocus: true, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Salvar')),
        ],
      ),
    );
    if (nome != null && mounted) setState(() => nome.isEmpty ? _pessoas.remove(i.objetivo) : _pessoas[i.objetivo] = nome);
  }

  Future<void> _migrar(List<MbMigItem> itens) async {
    final p = _previa;
    if (p == null || itens.isEmpty) return;
    final antigo = itens.fold<int>(0, (s, i) => s + i.saldoAntigoCentavos);
    final novo = itens.fold<int>(0, (s, i) => s + i.saldoNovoCentavos);
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('confirmar_migracao'),
        title: Text(itens.length == 1 ? 'Migrar este empréstimo?' : 'Migrar ${itens.length} empréstimos?'),
        content: Text('O saldo antigo (${_r(antigo)}) passa a ${_r(novo)} na tela Empréstimos'
            '${antigo == novo ? '' : '; a diferença está explicada em cada empréstimo'}.\n\n'
            'Os lançamentos antigos não são alterados e cada migração pode ser desfeita.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Migrar')),
        ],
      ),
    );
    if (confirmou != true) return;
    await _agir(() async {
      final c = await _cliente();
      if (c == null) throw 'Conecte o Meu Banco para migrar.';
      final r = await c.emprestimosMigrar([for (final i in itens) i.objetivo], p.assinatura,
          pessoas: {for (final i in itens) if (_pessoas[i.objetivo] != null) i.objetivo: _pessoas[i.objetivo]!}, ajustar: _ajustar);
      _escolhidos.clear();
      return 'Migrado: ${r.migrados} empréstimo(s). Em aberto: ${_r(r.antesCentavos)} → ${_r(r.depoisCentavos)}.';
    });
  }

  Future<void> _desfazer(MbMigItem i) async {
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desfazer a migração?'),
        content: const Text('As decisões migradas saem da tela Empréstimos e o empréstimo antigo volta a ficar como estava.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Desfazer')),
        ],
      ),
    );
    if (confirmou != true) return;
    await _agir(() async {
      final c = await _cliente();
      if (c == null) throw 'Conecte o Meu Banco para desfazer.';
      final r = await c.emprestimosDesfazerMigracao(i.objetivo);
      return 'Migração desfeita. Em aberto: ${_r(r.antesCentavos)} → ${_r(r.depoisCentavos)}.';
    });
  }

  Future<void> _agir(Future<String> Function() acao) async {
    setState(() {
      _ocupado = true;
      _erro = null;
    });
    String? aviso;
    try {
      aviso = await acao();
      if (widget.cliente == null) await sincronizarMeuBanco(); // traz as decisões novas para este aparelho
    } on MbErroHttp catch (e) {
      _erro = e.status == 409 ? '${e.mensagem} Recarreguei a prévia.' : e.mensagem;
    } catch (e) {
      _erro = mbErroDeRede(e) ?? '$e';
    }
    if (!mounted) return;
    if (aviso != null && snackbarKey.currentState != null) openSnackbar(SnackbarMessage(title: aviso));
    final erro = _erro; // a prévia recarregada não pode apagar o motivo (ex.: 409, dados mudaram)
    await _carregar(primeira: false);
    if (mounted && erro != null && _erro == null) setState(() => _erro = erro);
  }

  @override
  Widget build(BuildContext context) {
    final p = _previa;
    return PageFramework(
      title: 'Empréstimos antigos',
      horizontalPaddingConstrained: true,
      listWidgets: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Traz os empréstimos do modelo anterior para a tela Empréstimos. Nada muda até você confirmar, e dá para desfazer cada um.',
                style: EdTexto.corpo(context).copyWith(color: cores(context).mu)),
            const SizedBox(height: 16),
            if (_erro != null) _Erro(_erro!, onTentar: _carregar),
            if (p == null && _erro == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            if (p != null) ..._corpo(context, p),
          ]),
        ),
      ],
    );
  }

  List<Widget> _corpo(BuildContext context, MbMigPrevia p) {
    final cor = cores(context);
    final escolhaveis = p.migraveis;
    final prontos = [for (final i in escolhaveis) if (i.status != 'revisar') i];
    final selecionados = [for (final i in escolhaveis) if (_escolhidos.contains(i.objetivo)) i];
    return [
      _Resumo(p),
      const SizedBox(height: 16),
      if (escolhaveis.isEmpty && p.migrados.isEmpty)
        Text('Nenhum empréstimo antigo para migrar.', style: EdTexto.corpo(context).copyWith(color: cor.mu)),
      for (final i in escolhaveis) ...[
        _Cartao(
          i,
          pessoa: _pessoaDe(i),
          ajustando: _ajustar.contains(i.objetivo),
          escolhido: _escolhidos.contains(i.objetivo),
          ocupado: _ocupado,
          onEscolher: (v) => setState(() => v ? _escolhidos.add(i.objetivo) : _escolhidos.remove(i.objetivo)),
          onAjustar: (v) => _alternarAjuste(i, v),
          onPessoa: () => _editarPessoa(i),
          onMigrar: () => _migrar([i]),
        ),
        const SizedBox(height: 12),
      ],
      if (escolhaveis.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
              key: const Key('escolher_todos'),
              onPressed: _ocupado ? null : () => setState(() => selecionados.length == prontos.length ? _escolhidos.clear() : _escolhidos.addAll([for (final i in prontos) i.objetivo])),
              child: Text(selecionados.length == prontos.length ? 'Limpar seleção' : 'Selecionar todos'),
            ),
            FilledButton(
              key: const Key('migrar_selecionados'),
              onPressed: _ocupado || selecionados.isEmpty ? null : () => _migrar(selecionados),
              child: Text('Migrar selecionados (${selecionados.length})'),
            ),
          ]),
        ),
      if (p.migrados.isNotEmpty) ...[
        Text('Já migrados', style: EdTexto.rotulo(context)),
        const SizedBox(height: 8),
        for (final i in p.migrados) ...[
          _Migrado(i, ocupado: _ocupado, onDesfazer: () => _desfazer(i)),
          const SizedBox(height: 8),
        ],
      ],
      if (p.naoMapeaveis.isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('nao_mapeados'),
            tilePadding: EdgeInsets.zero,
            title: Text('Não migram (${p.naoMapeaveis.length})', style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
            children: [
              for (final i in p.naoMapeaveis)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(i.nome.isEmpty ? 'Sem nome' : i.nome, style: EdTexto.corpo(context)),
                    for (final m in i.motivos) Text(m, style: EdTexto.rotulo(context)),
                  ]),
                ),
            ],
          ),
        ),
    ];
  }
}

class _Resumo extends StatelessWidget {
  const _Resumo(this.p);
  final MbMigPrevia p;

  @override
  Widget build(BuildContext context) {
    final cor = cores(context);
    return Container(
      key: const Key('resumo_migracao'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cor.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: cor.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Emprestado em aberto', style: EdTexto.rotulo(context)),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(_r(p.antesCentavos), style: EdTexto.mono(context).copyWith(fontSize: 18, color: cor.mu)),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('→', style: EdTexto.corpo(context))),
          Text(_r(p.depoisCentavos), key: const Key('depois_total'), style: EdTexto.mono(context).copyWith(fontSize: 22, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        Text('Se migrar tudo o que está pronto. Saldo antigo ${_r(p.saldoAntigoCentavos)} · novo ${_r(p.saldoNovoCentavos)}'
            '${p.diferencaCentavos == 0 ? '' : ' · diferença ${_r(p.diferencaCentavos)} (explicada em cada empréstimo)'}.',
            style: EdTexto.rotulo(context)),
        if (p.efeitosQtd > 0) ...[
          const SizedBox(height: 4),
          Text('Devoluções já registradas sem empréstimo passam a abater estes: ${_r(p.efeitosCentavos)}.', key: const Key('efeitos'), style: EdTexto.rotulo(context)),
        ],
      ]),
    );
  }
}

class _Cartao extends StatelessWidget {
  const _Cartao(this.i, {required this.pessoa, required this.ajustando, required this.escolhido, required this.ocupado, required this.onEscolher, required this.onAjustar, required this.onPessoa, required this.onMigrar});
  final MbMigItem i;
  final String pessoa;
  final bool ajustando, escolhido, ocupado;
  final ValueChanged<bool> onEscolher, onAjustar;
  final VoidCallback onPessoa, onMigrar;

  @override
  Widget build(BuildContext context) {
    final cor = cores(context);
    final alt = i.alternativa;
    return Container(
      key: Key('item_${i.objetivo}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cor.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: cor.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Checkbox(key: Key('escolher_${i.objetivo}'), value: escolhido, onChanged: ocupado ? null : (v) => onEscolher(v == true)),
          Expanded(
            child: InkWell(
              onTap: onPessoa,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(pessoa.isEmpty ? 'Sem pessoa' : pessoa, style: EdTexto.corpo(context).copyWith(fontSize: 18, fontWeight: FontWeight.w600)),
                Text('${i.lancamentos} lançamentos · toque para mudar a pessoa', style: EdTexto.rotulo(context)),
              ]),
            ),
          ),
          if (i.status == 'revisar') Text('Revisar', style: EdTexto.rotulo(context).copyWith(color: Theme.of(context).colorScheme.error)),
        ]),
        const SizedBox(height: 8),
        _Linha('Emprestado', _r(i.originalCentavos)),
        _Linha('Já pago', _r(i.pagoCentavos)),
        _Linha('Saldo antigo', _r(i.saldoAntigoCentavos)),
        _Linha('Saldo na tela Empréstimos', _r(i.saldoNovoCentavos), forte: true),
        if (alt != null)
          SwitchListTile(
            key: Key('ajustar_${i.objetivo}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('Ajustar datas dos pagamentos', style: EdTexto.corpo(context)),
            subtitle: Text(
              ajustando
                  ? 'Pagamento adiantado vira crédito e abate o próximo empréstimo. Sem ajuste: ${_r(alt.saldoNovoCentavos)}.'
                  : 'Pagamento adiantado vira crédito e abate o próximo empréstimo. Com ajuste: ${_r(alt.saldoNovoCentavos)}.',
              style: EdTexto.rotulo(context),
            ),
            value: ajustando,
            onChanged: ocupado ? null : onAjustar,
          ),
        if (i.diferencas.isNotEmpty || i.avisos.isNotEmpty || i.motivos.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: Key('detalhes_${i.objetivo}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text('Diferença ${_r(i.diferencaCentavos)}${i.diferencas.isEmpty ? '' : ' · ${i.diferencas.length} item(ns)'}', style: EdTexto.rotulo(context)),
              children: [
                for (final m in i.motivos) Align(alignment: Alignment.centerLeft, child: Text(m, style: EdTexto.rotulo(context).copyWith(color: Theme.of(context).colorScheme.error))),
                for (final a in i.avisos) Align(alignment: Alignment.centerLeft, child: Text(a, style: EdTexto.rotulo(context))),
                for (final d in i.diferencas)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Text('${_data(d.data)} · ${d.motivo}', style: EdTexto.rotulo(context))),
                      Text(_r(d.centavos), style: EdTexto.mono(context)),
                    ]),
                  ),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(key: Key('migrar_${i.objetivo}'), onPressed: ocupado ? null : onMigrar, child: const Text('Migrar este')),
        ),
      ]),
    );
  }
}

class _Linha extends StatelessWidget {
  const _Linha(this.rotulo, this.valor, {this.forte = false});
  final String rotulo, valor;
  final bool forte;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(rotulo, style: EdTexto.corpo(context).copyWith(fontWeight: forte ? FontWeight.w600 : null))),
          Text(valor, style: EdTexto.mono(context).copyWith(fontWeight: forte ? FontWeight.w700 : null)),
        ]),
      );
}

class _Migrado extends StatelessWidget {
  const _Migrado(this.i, {required this.ocupado, required this.onDesfazer});
  final MbMigItem i;
  final bool ocupado;
  final VoidCallback onDesfazer;

  @override
  Widget build(BuildContext context) {
    final desatualizado = i.status == 'desatualizado';
    return Row(key: Key('migrado_${i.objetivo}'), children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(i.pessoa ?? 'Sem pessoa', style: EdTexto.corpo(context)),
          Text(desatualizado ? i.motivos.join(' ') : 'Migrado · saldo ${_r(i.saldoNovoCentavos)}', style: EdTexto.rotulo(context)),
        ]),
      ),
      TextButton(key: Key('desfazer_${i.objetivo}'), onPressed: ocupado ? null : onDesfazer, child: const Text('Desfazer')),
    ]);
  }
}

class _Erro extends StatelessWidget {
  const _Erro(this.mensagem, {required this.onTentar});
  final String mensagem;
  final VoidCallback onTentar;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Expanded(child: Text(mensagem, key: const Key('erro_migracao'), style: EdTexto.corpo(context).copyWith(color: Theme.of(context).colorScheme.error))),
          TextButton(onPressed: onTentar, child: const Text('Tentar de novo')),
        ]),
      );
}
