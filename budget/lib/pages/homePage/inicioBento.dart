part of 'inicioEditorial.dart';

// Início do celular em cartões (Bento): cada bloco é um cartão sobre o fundo da tela.

Widget _acaoBento(BuildContext context, String rotulo, VoidCallback onTap) =>
    TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          alignment: Alignment.centerRight,
          visualDensity: VisualDensity.compact,
          foregroundColor: cores(context).acc),
      child: Text(rotulo),
    );

/// Cartão do ciclo: quanto ainda dá para gastar, a barra do limite e gasto, por dia e ritmo.
/// Sem limite definido: o saldo das contas e o atalho para definir.
class CicloBento extends StatelessWidget {
  const CicloBento(
      {super.key, required this.modelo, this.onTap, this.onDefinirLimite});
  final ModeloInicio modelo;
  final VoidCallback? onTap, onDefinirLimite;

  @override
  Widget build(BuildContext context) {
    final limite = modelo.limite;
    final cartao = CartaoBento(
      padding: const EdgeInsets.all(20),
      child: limite != null && limite > 0
          ? _CicloComLimite(modelo: modelo, limite: limite)
          : _SemLimite(modelo: modelo, onDefinirLimite: onDefinirLimite),
    );
    if (onTap == null) return cartao;
    return Semantics(
        button: true,
        label: 'Abrir orçamento do ciclo',
        child: ToqueEscala(onTap: onTap, child: cartao));
  }
}

class _CicloComLimite extends StatelessWidget {
  const _CicloComLimite({required this.modelo, required this.limite});
  final ModeloInicio modelo;
  final double limite;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final restante = limite - modelo.consumido;
    final estourou = restante < 0;
    // diasRestantes não conta hoje; aqui hoje entra, como no cartão do orçamento (último dia = 1).
    final dias = max(0, modelo.diasRestantes) + 1;
    final hoje = modelo.fracaoHoje;
    final dif =
        hoje == null ? null : modelo.consumido - idealAteHoje(limite, hoje);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Text(
                estourou ? 'Acima do limite do ciclo' : 'Livre no ciclo',
                style: EdTexto.corpo(context).copyWith(color: e.mu)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                color: e.chip, borderRadius: BorderRadius.circular(99)),
            child: Text(dias == 1 ? 'último dia' : '$dias dias',
                style: EdTexto.rotulo(context)),
          ),
        ]),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: ContagemValor(
              valor: restante.abs(),
              formatar: brl,
              centavosMenores: true,
              estilo: EdTexto.numeroGrande(context)
                  .copyWith(fontSize: 46, color: estourou ? e.warn : null)),
        ),
        const SizedBox(height: 14),
        MedidorEditorial(
            fracao: modelo.consumido / limite,
            aVencer: modelo.aVencer / limite,
            alerta: estourou,
            cor: e.tx,
            hoje: hoje,
            altura: 8),
        const SizedBox(height: 14),
        Divider(height: 1, thickness: 1, color: e.line),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Dado('Gasto', _brl0(modelo.consumido)),
          if (modelo.aVencer > 0) _Dado('A vencer', _brl0(modelo.aVencer)),
          if (!estourou && AjustesInicio.ritmoDiario)
            _Dado('Por dia', _brl0(restante / dias)),
          if (dif != null)
            dif.abs() < .5
                ? const _Dado('Ritmo', 'No ritmo')
                : _Dado('Ritmo',
                    '${_brl0(dif.abs())} ${dif > 0 ? 'acima' : 'abaixo'}',
                    cor: dif > 0 ? e.warn : e.pos),
        ]),
      ],
    );
  }
}

class _Dado extends StatelessWidget {
  const _Dado(this.rotulo, this.valor, {this.cor});
  final String rotulo, valor;
  final Color? cor;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Semantics(
          label: '$rotulo $valor',
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rotulo, maxLines: 1, style: EdTexto.rotulo(context)),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(valor,
                    maxLines: 1,
                    style: EdTexto.corpo(context)
                        .copyWith(fontWeight: FontWeight.w600, color: cor)),
              ),
            ],
          ),
        ),
      );
}

/// Avisos logo abaixo do ciclo: transações para validar e a fatura que vence em até 3 dias.
/// Dois avisos ficam lado a lado; um só ocupa a largura toda; sem avisos, some.
class AlertasBento extends StatelessWidget {
  const AlertasBento({super.key, this.bancos = const [], this.onAbrir});
  final List<BancoInicio> bancos;
  final void Function(String carteiras)? onAbrir;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([meuBancoRevisar, meuBancoClassificar]),
        builder: (context, _) {
          final p = _paraValidar();
          final avisos = [
            if (p.n > 0)
              _Aviso(
                rotulo: 'Para validar',
                valor: p.n == 1 ? '1 transação' : '${p.n} transações',
                detalhe: p.total > 0 ? '${brl(p.total)} · Revisar' : 'Revisar',
                semantica: '${p.n} para validar',
                onTap: () => pushRoute(context, const PendenciasPage()),
              ),
            for (final b in bancos)
              for (final i in b.itens)
                if (i.fatura && i.destaque)
                  _Aviso(
                    rotulo: b.nome,
                    valor: brl(i.valor.abs()),
                    detalhe: i.rotulo,
                    semantica: '${b.nome}, ${i.rotulo}, ${brl(i.valor.abs())}',
                    onTap: onAbrir == null ? null : () => onAbrir!(i.carteiras),
                  ),
          ];
          if (avisos.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child:
                avisos.length == 1 ? avisos.first : GradeBento(filhos: avisos),
          );
        },
      );
}

class _Aviso extends StatelessWidget {
  const _Aviso(
      {required this.rotulo,
      required this.valor,
      required this.detalhe,
      required this.semantica,
      this.onTap});
  final String rotulo, valor, detalhe, semantica;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final texto = EdTexto.rotulo(context).copyWith(color: e.warntx);
    return Semantics(
      button: true,
      label: semantica,
      excludeSemantics: true,
      onTap: onTap,
      child: ToqueEscala(
        onTap: onTap,
        child: CartaoBento(
          cor: e.warnbg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rotulo,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: texto),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(valor,
                    maxLines: 1,
                    style: EdTexto.corpo(context).copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: e.warntx)),
              ),
              const SizedBox(height: 2),
              Text(detalhe,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: texto),
            ],
          ),
        ),
      ),
    );
  }
}

/// Anel de progresso com a porcentagem no centro; vermelho em alerta.
class _Anel extends StatelessWidget {
  const _Anel(this.fracao, {this.alerta = false, this.tamanho = 52});
  final double fracao, tamanho;
  final bool alerta;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    Widget anel(double v) => CircularProgressIndicator(
        value: v,
        strokeWidth: 5,
        strokeCap: StrokeCap.round,
        color: alerta ? e.warn : e.tx,
        backgroundColor: e.line);
    final alvo = fracao.clamp(0.0, 1.0);
    return SizedBox.square(
      dimension: tamanho,
      child: Stack(fit: StackFit.expand, children: [
        semMovimento(context)
            ? anel(alvo)
            : TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: alvo),
                duration: const Duration(milliseconds: 900),
                curve: curvaEditorial,
                builder: (context, v, _) => anel(v),
              ),
        Center(
          child: Text('${(fracao * 100).round()}%',
              style: EdTexto.rotulo(context).copyWith(
                  fontWeight: FontWeight.w600, color: alerta ? e.warn : e.tx)),
        ),
      ]),
    );
  }
}

class _LimitesBento extends StatelessWidget {
  const _LimitesBento(this.limites);
  final List<LimiteInicio> limites;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TituloBento('Limites',
              fim: _acaoBento(
                  context,
                  'Orçamentos',
                  () => pushRoute(
                      context, const BudgetsListPage(enableBackButton: true)))),
          CartaoBento(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final l in limites)
                Expanded(
                  child: Semantics(
                    label: '${l.nome}, ${brl(l.gasto)} de ${brl(l.limite)}',
                    excludeSemantics: true,
                    child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(children: [
                          _Anel(l.gasto / l.limite,
                              alerta: l.gasto / l.limite >= .9),
                          const SizedBox(height: 10),
                          Text(l.nome,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: EdTexto.corpo(context)
                                  .copyWith(fontWeight: FontWeight.w500)),
                          FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                  '${_brl0(l.gasto)} de ${_brl0(l.limite)}',
                                  style: EdTexto.rotulo(context))),
                        ])),
                  ),
                ),
            ]),
          ),
        ],
      );
}

class _MetaBento extends StatelessWidget {
  const _MetaBento(
      {required this.nome,
      required this.total,
      required this.alvo,
      required this.fracao,
      this.onTap});
  final String nome;
  final double total, alvo, fracao;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: onTap != null,
        label: '$nome, ${brl(total)} de ${brl(alvo)}',
        excludeSemantics: true,
        onTap: onTap,
        child: ToqueEscala(
          onTap: onTap,
          child: CartaoBento(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Anel(fracao, tamanho: 46),
                const SizedBox(height: 12),
                Text(nome,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context)
                        .copyWith(fontWeight: FontWeight.w500)),
                FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('${_brl0(total)} de ${_brl0(alvo)}',
                        style: EdTexto.rotulo(context))),
              ],
            ),
          ),
        ),
      );
}
