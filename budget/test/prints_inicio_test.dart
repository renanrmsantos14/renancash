// Prints completos da Início (celular 390x844 e desktop 1440x900, claro e escuro).
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_inicio_test.dart --update-goldens
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/homePage/homePageFaturaPatrimonio.dart';
import 'package:budget/pages/homePage/inicioEditorial.dart';
import 'package:budget/pages/homePage/painelDesktop.dart';
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/avisos.dart' show meuBancoAvisos;
import 'package:budget/struct/mbSync/classificar.dart' show MbLancamentoIa;
import 'package:budget/struct/mbSync/classificarDados.dart' show meuBancoClassificar;
import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/meuBancoSync.dart'
    show meuBancoPareado, meuBancoPareadoConferido, meuBancoUltimaSync;
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/editorial/lateralEditorial.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _fonte(String familia, List<String> arquivos) async {
  final l = FontLoader(familia);
  for (final a in arquivos) {
    l.addFont(Future.value(ByteData.sublistView(File(a).readAsBytesSync())));
  }
  await l.load();
}

final _pular = Platform.environment['PRINTS'] != '1';
final _agora = DateTime(2026, 11, 12, 15, 0);

Map<String, dynamic> _padroes = {};
Map<String, dynamic> _ajustes(String modo) => {
      ..._padroes,
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
      'outlinedIcons': true,
      'font': 'Geist',
      'acento': 'verde',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

const _metasExemplo = [
  (nome: 'Reserva de emergência', total: 7649.50, alvo: 10000.0),
  (nome: 'Viagem 2027', total: 2400.00, alvo: 6000.0),
  (nome: 'Troca de notebook', total: 1500.00, alvo: 5000.0),
];

const _limitesExemplo = [
  (nome: 'Alimentação', gasto: 912.30, limite: 1000.0),
  (nome: 'Transporte', gasto: 388.10, limite: 600.0),
  (nome: 'Lazer', gasto: 140.0, limite: 400.0),
];

// Contas, cartões e aplicações do print: Inter e Nubank com logo, um banco sem logo (Pan: selo com
// iniciais) com fatura vencendo em 2 dias (destaque), XP só com investimentos e aplicações sem banco (Outros).
final _contasBancos = <Map<String, dynamic>>[
  {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'bank': 'Banco Inter ·69-6', 'balance': 893.47},
  {'id': 'p1', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poupança Inter', 'bank': 'Banco Inter', 'balance': 500.0},
  {'id': 'b', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Nubank', 'bank': 'Nubank', 'balance': 1115.50},
  {'id': 'd', 'type': 'CREDIT', 'name': 'Ultravioleta ·4412', 'bank': 'Nubank', 'balance': 1240.0, 'due_date': '2026-11-22'},
  {'id': 'p2', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poupança Santander', 'bank': 'Banco Santander', 'balance': 120.0},
  {'id': 'e', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Pan', 'bank': 'Banco Pan', 'balance': 215.40},
  {'id': 'f', 'type': 'CREDIT', 'name': 'Pan Mastercard ·7788', 'bank': 'Banco Pan', 'balance': 569.0, 'due_date': '2026-11-14'},
];

const _investimentosBancos = <InvestimentoBanco>[
  (nome: 'CDB - BANCO INTER', banco: 'BANCO INTER', saldo: 1049.0),
  (nome: 'CDB - BANCO INTER', banco: 'BANCO INTER', saldo: 5200.0),
  (nome: 'LCI - BANCO INTER', banco: 'BANCO INTER', saldo: 3100.0),
  (nome: 'Fundo DI', banco: 'XP Investimentos', saldo: 7000.0),
  (nome: 'Tesouro Selic', banco: null, saldo: 2081.0),
];

PatrimonioInicio _patrimonioDe(List<Map<String, dynamic>> contas,
    List<InvestimentoBanco> invest) {
  double soma(bool poup) => contas
      .where((c) =>
          c['type'] == 'BANK' && (c['subtype'] == 'SAVINGS_ACCOUNT') == poup)
      .fold<double>(0, (s, c) => s + (c['balance'] as double));
  final faturas =
      mbFaturasAbertas(contas: contas, faturas: const {}, agora: _agora);
  return (
    patrimonio: mbPatrimonio(
        correntes: soma(false),
        poupancas: soma(true),
        investimentos: invest.fold<double>(0, (s, i) => s + i.saldo),
        fatura: faturas.fold<double>(0, (s, f) => s + f.valor)),
    faturas: faturas,
    carteiras: const <CarteiraInicio>[],
    bancos: mbAgruparPorBanco(
        contas: contas,
        faturas: const {},
        investimentos: invest,
        sincronizadoEm:
            _agora.toUtc().toIso8601String(),
        agora: _agora),
    semDados: false,
  );
}

final _patrimonioExemplo = _patrimonioDe(_contasBancos, _investimentosBancos);

// Sem investimentos e com um banco desconhecido: só conta, e a fatura em destaque.
final _patrimonioSemInvestimentos = _patrimonioDe([
  _contasBancos[0],
  _contasBancos[5],
  _contasBancos[6],
], const []);

/// Imagens de `assets/` só carregam fora do relógio falso do teste: decodifica antes do print.
Future<void> _logos(WidgetTester t) async {
  await t.runAsync(() async {
    final contexto = t.element(find.byType(MaterialApp));
    for (final img in t.widgetList<Image>(find.byType(Image))) {
      await precacheImage(img.image, contexto);
    }
  });
  await t.pump(const Duration(milliseconds: 100));
}

/// Fila "Para classificar" de exemplo (3 itens, R$ 212,40) e sincronização "há 4 min".
void _pendenciasExemplo() {
  meuBancoClassificar.value = [
    for (final (i, v) in [120.40, 62.0, 30.0].indexed)
      MbLancamentoIa(
          pk: 'p$i', descricao: 'Compra $i', valor: -v, data: DateTime(2026, 11, 11)),
  ];
  meuBancoUltimaSync.value = DateTime.now().subtract(const Duration(minutes: 4));
}

void _limparPendencias() {
  meuBancoClassificar.value = const [];
  meuBancoUltimaSync.value = null;
}

final _ultimasExemplo = [
  _ultima('u1', 'Pão de Açúcar', 'Mercado', -182.30, DateTime.now()),
  _ultima('u2', 'Almoço Betinhos', 'Alimentação', -20.98,
      DateTime.now().subtract(const Duration(days: 1))),
  _ultima('u3', 'Uber', 'Transporte', -27.90,
      DateTime.now().subtract(const Duration(days: 1))),
  _ultima('u4', 'Salário', 'Receita', 6500.0, DateTime(2026, 11, 5)),
  _ultima('u5', 'Compra avulsa', 'Sem categoria', -49.90, DateTime(2026, 11, 4)),
];

const _emprestimosExemplo = MbEmprestimos([
  MbEmprestimo('e1', '2026-10-18', 80000, 35000),
  MbEmprestimo('e2', '2026-11-03', 50000, 50000),
  MbEmprestimo('e3', '2026-11-10', 20000, 20000),
]);

ModeloInicio _modeloCompleto() => montarModeloInicio(
      geral: (limite: 4630.0, gasto: 2871.15, aVencer: 320.0),
      ciclo: {
        'inicio': '2026-10-26',
        'fim': '2026-11-25',
        'consumido': 2871.15,
        'limite': 4630.0,
        'percentual': 62.0,
        'diasRestantes': 13,
        'por_dia': [
          for (var i = 0; i < 31; i++)
            {
              'data': DateTime(2026, 10, 26 + i)
                  .toIso8601String()
                  .substring(0, 10),
              'valor': i <= 17 ? (i * 37 % 140 + 40).toDouble() : 0.0
            }
        ],
      },
      contas: [
        {
          'id': 'a',
          'type': 'BANK',
          'subtype': 'CHECKING_ACCOUNT',
          'name': 'Conta Inter',
          'bank': 'Banco Inter',
          'balance': 3102.90
        },
        {
          'id': 'b',
          'type': 'BANK',
          'subtype': 'CHECKING_ACCOUNT',
          'name': 'Conta Nubank',
          'bank': 'Nubank',
          'balance': 1115.50
        },
        {
          'id': 'p1',
          'type': 'BANK',
          'subtype': 'SAVINGS_ACCOUNT',
          'name': 'Poupança Inter',
          'bank': 'Banco Inter',
          'balance': 500.00
        },
        {
          'id': 'p2',
          'type': 'BANK',
          'subtype': 'SAVINGS_ACCOUNT',
          'name': 'Poupança Santander',
          'bank': 'Banco Santander',
          'balance': 120.00
        },
        {
          'id': 'd',
          'type': 'CREDIT',
          'name': 'Ultravioleta ·4412',
          'bank': 'Nubank',
          'balance': 1240.0,
          'credit_limit': 3000.0,
          'closing_date': '2026-11-15',
          'due_date': '2026-11-22',
        },
      ],
      faturas: {},
      sincronizadoEm:
          _agora.subtract(const Duration(minutes: 4)).toUtc().toIso8601String(),
      nome: 'Renan',
      agora: _agora,
    );

ModeloInicio _modeloSemLimite() => montarModeloInicio(
      ciclo: {
        'inicio': '2026-10-26',
        'fim': '2026-11-25',
        'consumido': 1245.80,
      },
      contas: [
        {
          'id': 'a',
          'type': 'BANK',
          'subtype': 'CHECKING_ACCOUNT',
          'name': 'Banco Inter ·69-6',
          'bank': 'Banco Inter',
          'balance': 2410.00
        },
        {
          'id': 'p1',
          'type': 'BANK',
          'subtype': 'SAVINGS_ACCOUNT',
          'name': 'Conta Poupança',
          'bank': 'Banco Inter',
          'balance': 500.00
        },
        {
          'id': 'p2',
          'type': 'BANK',
          'subtype': 'SAVINGS_ACCOUNT',
          'name': 'Cartão Poup',
          'bank': 'Banco Santander',
          'balance': 120.00
        },
      ],
      faturas: {},
      agruparPoupancas: false,
      sincronizadoEm:
          _agora.subtract(const Duration(minutes: 4)).toUtc().toIso8601String(),
      nome: 'Renan',
      agora: _agora,
    );

ModeloInicio _modeloEstourado() => montarModeloInicio(
      geral: (limite: 4000.0, gasto: 4380.50, aVencer: 0),
      ciclo: {
        'inicio': '2026-10-26',
        'fim': '2026-11-12',
        'consumido': 4380.50,
        'limite': 4000.0,
        'diasRestantes': 0,
      },
      contas: [
        {
          'id': 'a',
          'type': 'BANK',
          'subtype': 'CHECKING_ACCOUNT',
          'name': 'Conta Inter',
          'bank': 'Banco Inter',
          'balance': 950.00
        },
      ],
      faturas: {},
      sincronizadoEm: null,
      nome: 'Renan',
      agora: _agora,
    );

ModeloInicio _modeloVazio() => montarModeloInicio(
      ciclo: {},
      contas: const [],
      faturas: const {},
      sincronizadoEm: null,
      nome: 'Renan',
      agora: _agora,
    );

TransacaoInicio _ultima(String pk, String nome, String categoria, double valor,
        DateTime data) =>
    (
      category: TransactionCategory(
          categoryPk: 'c-$categoria',
          name: categoria,
          dateCreated: DateTime(2026),
          dateTimeModified: null,
          order: 0,
          income: valor > 0,
          methodAdded: null),
      transaction: Transaction(
          transactionPk: pk,
          name: nome,
          amount: valor,
          note: '',
          categoryFk: 'c-$categoria',
          walletFk: '0',
          dateCreated: data,
          income: valor > 0,
          paid: true,
          skipPaid: false,
          createdAnotherFutureTransaction: false,
          type: null,
          methodAdded: null,
          reoccurrence: null,
          endDate: null,
          periodLength: null,
          dateTimeModified: null,
          originalDateDue: null,
          sharedKey: null,
          sharedOldKey: null,
          sharedDateUpdated: null,
          sharedReferenceBudgetPk: null,
          sharedStatus: null,
          objectiveFk: null,
          objectiveLoanFk: null,
          upcomingTransactionNotification: null,
          subCategoryFk: null,
          transactionOwnerEmail: null,
          transactionOriginalOwnerEmail: null),
    );

void main() {
  setUpAll(() async {
    _padroes = await getDefaultPreferences();
    const f = 'assets/fonts/';
    await _fonte('Geist', [
      '${f}Geist-Regular.ttf',
      '${f}Geist-Medium.ttf',
      '${f}Geist-SemiBold.ttf',
    ]);
    await _fonte(
        'GeistMono', ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ??
        'C:/Users/mendo/development/flutter-3.24.5';
    await _fonte('MaterialIcons',
        ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  for (final modo in ['claro', 'escuro']) {
    final b = modo == 'claro' ? Brightness.light : Brightness.dark;

    // Página inteira (rola no aparelho): viewport alto para o print mostrar todas as seções.
    testWidgets('print inicio editorial completo $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoEmprestimos.value = _emprestimosExemplo;
      _pendenciasExemplo();
      addTearDown(() {
        meuBancoEmprestimos.value = const MbEmprestimos();
        _limparPendencias();
      });
      t.view.physicalSize = const Size(390 * 2, 2300 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(
          body: InicioEditorial.comModelo(
            _modeloCompleto(),
            metas: _metasExemplo,
            patrimonio: _patrimonioExemplo,
            limites: _limitesExemplo,
            transacoes: _ultimasExemplo,
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 3));
      await _logos(t);
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_editorial_completo_$modo.png'));
    });

    // Sem limite no Geral: o cartão pede "Definir limite do ciclo"; as demais seções seguem.
    testWidgets('print inicio painel sem limite $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _pendenciasExemplo();
      addTearDown(_limparPendencias);
      t.view.physicalSize = const Size(390 * 2, 1700 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(
          body: InicioEditorial.comModelo(
            _modeloSemLimite(),
            patrimonio: _patrimonioExemplo,
            transacoes: _ultimasExemplo,
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 3));
      await _logos(t);
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_painel_sem_limite_$modo.png'));
    });

    testWidgets('print inicio metas emprestimos e contas $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoEmprestimos.value = _emprestimosExemplo;
      addTearDown(() => meuBancoEmprestimos.value = const MbEmprestimos());
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(
          body: InicioEditorial.comModelo(
            _modeloCompleto(),
            metas: _metasExemplo,
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 3));
      await _logos(t);
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_editorial_metas_contas_$modo.png'));
    });

    // Sem investimentos, banco sem logo (selo com iniciais) e fatura vencendo em 2 dias em destaque.
    testWidgets('print inicio bancos sem logo e sem investimentos $modo',
        skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      t.view.physicalSize = const Size(390 * 2, 1500 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(
          body: InicioEditorial.comModelo(
            _modeloCompleto(),
            patrimonio: _patrimonioSemInvestimentos,
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 3));
      await _logos(t);
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_bancos_sem_logo_$modo.png'));
    });

    testWidgets('print inicio sem limite e estourado $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoEmprestimos.value = _emprestimosExemplo;
      addTearDown(() => meuBancoEmprestimos.value = const MbEmprestimos());
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final semLimite = _modeloSemLimite();
      final estourado = _modeloEstourado();
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(
          body: Builder(
            builder: (context) => ColoredBox(
              color: cores(context).bg,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                children: [
                  CartaoSaldoCiclo(
                    modelo: semLimite,
                    onDefinirLimite: () {},
                  ),
                  const SizedBox(height: 16),
                  CartaoSaldoCiclo(modelo: estourado),
                  const MetasEmprestimosInicio(metas: []),
                  BancosPorBanco(fixo: _patrimonioSemInvestimentos),
                ],
              ),
            ),
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 3));
      await _logos(t);
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_editorial_sem_limite_estourado_$modo.png'));
    });

    testWidgets('print inicio sem dados pareado $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoPareado.value = true;
      addTearDown(() => meuBancoPareado.value = false);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(body: InicioEditorial.comModelo(_modeloVazio())),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_editorial_sem_dados_$modo.png'));
    });

    testWidgets('print inicio sem banco pareado $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoPareado.value = false;
      meuBancoPareadoConferido.value = true;
      addTearDown(() => meuBancoPareadoConferido.value = false);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(
          body: InicioEditorial.comModelo(
            _modeloVazio(),
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_editorial_sem_banco_$modo.png'));
    });

    testWidgets('print inicio patrimonio e fatura $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final dados = (
        patrimonio: mbPatrimonio(
          correntes: 4218.40,
          poupancas: 620.00,
          investimentos: 12450.00,
          fatura: 1240.00,
        ),
        faturas: mbFaturasAbertas(
          contas: [
            {
              'id': 'c1',
              'type': 'CREDIT',
              'name': 'Ultravioleta ·4412',
              'balance': 940.00,
              'due_date': '2026-11-14',
            },
            {
              'id': 'c2',
              'type': 'CREDIT',
              'name': 'Cartão Gold ·1950',
              'balance': 300.00,
              'due_date': '2026-11-25',
            },
          ],
          faturas: const {},
          agora: _agora,
        ),
        carteiras: const [
          (nome: 'Dinheiro na carteira', saldo: 185.00),
          (nome: 'Caixinha viagem', saldo: 450.00),
        ],
        bancos: const <BancoInicio>[],
        semDados: false,
      );
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Builder(
          builder: (context) => Scaffold(
            backgroundColor: cores(context).bg,
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(13, 4, 13, 10),
                    child: Text('Análise', style: EdTexto.h2(context)),
                  ),
                  HomePagePatrimonio(dados),
                ],
              ),
            ),
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_patrimonio_fatura_$modo.png'));
    });

    testWidgets('print inicio conexao caida $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoAvisos.value = const [
        {'banco': 'Banco Inter', 'item_id': 'i1'},
        {'banco': 'Nubank', 'item_id': 'i2'},
      ];
      addTearDown(() => meuBancoAvisos.value = const []);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: const Scaffold(body: PendenciasPage(atualizar: false)),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_conexao_caida_$modo.png'));
    });

    testWidgets('print inicio desktop 1440x900 completo $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoPareado.value = true;
      meuBancoEmprestimos.value = _emprestimosExemplo;
      _pendenciasExemplo();
      addTearDown(() {
        meuBancoPareado.value = false;
        meuBancoEmprestimos.value = const MbEmprestimos();
        _limparPendencias();
      });
      t.view.physicalSize = const Size(1440, 1300);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: LayoutDesktop(
          lateral: LateralEditorial.comDados(
            contas: const [
              (id: 'a', nome: 'Banco Inter'),
              (id: 'b', nome: 'Nubank'),
            ],
            sincronizadoEm: DateTime.now().subtract(const Duration(minutes: 4)),
          ),
          conteudo: PainelDesktop.comDados(
            _modeloCompleto(),
            metas: _metasExemplo,
            patrimonio: _patrimonioExemplo,
            limites: _limitesExemplo,
            transacoes: _ultimasExemplo,
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 3));
      await _logos(t);
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_desktop_1440_completo_$modo.png'));
    });

    testWidgets('print inicio desktop 1440x900 sem banco $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoPareado.value = false;
      meuBancoPareadoConferido.value = true;
      addTearDown(() => meuBancoPareadoConferido.value = false);
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: LayoutDesktop(
          lateral: const LateralEditorial.comDados(contas: []),
          conteudo: PainelDesktop.comDados(_modeloVazio()),
        ),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_desktop_1440_sem_banco_$modo.png'));
    });

    testWidgets('print inicio desktop 1440x900 sem dados $modo', skip: _pular,
        (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoPareado.value = true;
      addTearDown(() => meuBancoPareado.value = false);
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: LayoutDesktop(
          lateral: const LateralEditorial.comDados(contas: []),
          conteudo: PainelDesktop.comDados(_modeloVazio()),
        ),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/inicio_desktop_1440_sem_dados_$modo.png'));
    });
  }
}
