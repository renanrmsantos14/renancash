import 'dart:convert';
import 'dart:ffi';

import 'package:budget/database/initializeDefaultDatabase.dart' show defaultWallet;
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:budget/struct/mbSync/bancos.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

// Poupança (SAVINGS_ACCOUNT) é aplicação: conta em "Investido", não em "Nas contas".
// Aplicação nova (inclusive poupança) vai uma única vez para a Reserva de emergência.

const _inter = {'id': 'pp1', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poupança', 'bank': 'BANCO INTER', 'balance': 0.33};
const _corrente = {'id': 'cc1', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'bank': 'BANCO INTER', 'balance': 1000.0};

Future<void> _aplicacao(String pk, double saldo, {String nome = 'CDB'}) =>
    database.into(database.transactions).insert(TransactionsCompanion.insert(
        transactionPk: Value(pk),
        name: nome,
        amount: saldo,
        note: 'Banco Inter',
        categoryFk: '0',
        walletFk: Value(mbCarteiraInvestimentos),
        dateCreated: Value(DateTime(2026, 11, 5)),
        income: const Value(true),
        dateTimeModified: Value(DateTime(2026, 11, 5))));

void main() {
  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    database = FinanceDatabase(NativeDatabase.memory());
    await database.createOrUpdateWallet(defaultWallet());
    await database.createOrUpdateWallet(
        defaultWallet().copyWith(walletPk: mbCarteiraInvestimentos, name: 'Investimentos'));
    await mbCriarTabelas();
  });

  tearDown(() => database.close());

  group('poupança como aplicação', () {
    test('Worker sem `bank`: a poupança leva o banco pelo nome da conta (Inter e Santander)', () {
      const inter = {'id': 'p1', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'BANCO INTER ·69-6', 'bank': null, 'balance': 600.33, 'item_id': 'i1'};
      const santander = {'id': 'p2', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Banco Santander Pessoa Física ·24-1', 'bank': null, 'balance': 1.06, 'item_id': 's1'};
      final a = mbPoupancaComoInvestimento(inter)!;
      expect((a.nome, a.banco), ('Poupança Inter', 'BANCO INTER ·69-6'));
      final b = mbPoupancaComoInvestimento(santander)!;
      expect((b.nome, mbBancoConhecido(b.banco)?.id), ('Poupança Santander', 'santander'));
    });

    test('conta sem banco reconhecível herda o da mesma conexão (item_id), ignoradas inclusive', () {
      final r = mbHerdarBanco([
        {'id': 'c1', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'BANCO INTER ·69-6', 'item_id': 'i1'},
        {'id': 'g', 'type': 'CREDIT', 'name': 'GOLD', 'item_id': 'i1'},
        {'id': 'x', 'type': 'CREDIT', 'name': 'GOLD', 'item_id': 'outra'},
        {'id': 'pai', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Banco Santander Pessoa Física ·57-2', 'item_id': 's1'},
        {'id': 'poup', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poupança', 'item_id': 's1'},
      ]);
      expect(r.firstWhere((c) => c['id'] == 'g')['bank'], 'Banco Inter');
      expect(r.firstWhere((c) => c['id'] == 'x')['bank'], isNull);
      expect(r.firstWhere((c) => c['id'] == 'c1')['bank'], isNull);
      expect(mbPoupancaComoInvestimento(r.last)!.nome, 'Poupança Santander');
    });

    test('o mapeamento a troca de carteira por aplicação "Poupança Inter"', () {
      expect(mbEhPoupanca(_inter), true);
      expect(mbEhPoupanca(_corrente), false);
      final i = mbPoupancaComoInvestimento(_inter)!;
      expect(i.pk, 'mb:inv:cc-pp1');
      expect(i.nome, 'Poupança Inter');
      expect(i.saldo, 0.33);
      expect(mbSemPoupancas([_inter, _corrente]), [_corrente]);
      // Conta do pai (corrente do Santander) segue ignorada e não vira aplicação.
      const pai = {'id': 'x', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Santander ·57-2', 'bank': 'Santander', 'balance': 5.0};
      expect(mbEhPoupanca(pai), false);
      expect(mbPoupancaComoInvestimento(pai), isNull);
    });

    test('sai de "Nas contas" e entra em Investido sem mudar o patrimônio', () async {
      final agora = DateTime(2026, 11, 18);
      await mbGravarEstado({'contas': jsonEncode([_corrente, _inter]), 'faturas': '{}'});
      final antes = await mbCarregarPatrimonioInicio(agora);
      expect(antes.patrimonio.correntes + antes.patrimonio.poupancas, 1000);
      expect(antes.patrimonio.investimentos, 0);

      await _aplicacao('mb:inv:cc-pp1', 0.33, nome: 'Poupança Inter');
      final depois = await mbCarregarPatrimonioInicio(agora);
      expect(depois.patrimonio.correntes + depois.patrimonio.poupancas, 1000);
      expect(depois.patrimonio.poupancas, 0);
      expect(depois.patrimonio.investimentos, 0.33);
      expect(depois.patrimonio.total, closeTo(1000.33, 1e-9));
      final inter = depois.bancos.single;
      expect(inter.itens.map((i) => i.rotulo), ['Conta corrente', 'Poupança Inter']);
    });

    test('a lista de contas da Início não tem a poupança', () async {
      await mbGravarEstado({'contas': jsonEncode([_corrente, _inter]), 'faturas': '{}'});
      final m = (await mbCarregarModeloInicio('Renan', DateTime(2026, 11, 18))).modelo;
      expect(m.contas.map((c) => c.tipo), ['Conta corrente']);
    });
  });

  group('vínculo inicial à Reserva', () {
    Future<Map<String, String>> vinculos() => mbVinculosMetas();

    test('sem Reserva nada é vinculado nem marcado como visto', () async {
      await _aplicacao('mb:inv:a', 10);
      await mbVincularAplicacoesNovas();
      expect(await vinculos(), isEmpty);
      await mbGarantirReserva();
      await mbVincularAplicacoesNovas();
      expect(await vinculos(), {'mb:inv:a': mbMetaReservaPk});
    });

    test('vincula uma vez: desvínculo manual persiste após novo sync; aplicação nova é vinculada', () async {
      await mbGarantirReserva();
      await _aplicacao('mb:inv:a', 10);
      await _aplicacao('mb:inv:cc-pp1', 0.33, nome: 'Poupança Inter');
      await mbVincularAplicacoesNovas();
      expect(await vinculos(),
          {'mb:inv:a': mbMetaReservaPk, 'mb:inv:cc-pp1': mbMetaReservaPk});
      expect((await mbAplicacoes()).every((a) => a.metaPk == mbMetaReservaPk), true);

      // Usuário tira a poupança da Reserva (tela da meta): fica fora, mesmo depois de outros syncs.
      final reserva = await (database.select(database.objectives)
            ..where((o) => o.objectivePk.equals(mbMetaReservaPk)))
          .getSingle();
      await mbEscolherAplicacoesDaMeta(reserva, {'mb:inv:a'});
      await mbVincularAplicacoesNovas();
      await mbVincularAplicacoesNovas();
      expect(await vinculos(), {'mb:inv:a': mbMetaReservaPk});

      // Aplicação nova que aparece depois entra na Reserva, uma vez.
      await _aplicacao('mb:inv:b', 5);
      await mbVincularAplicacoesNovas();
      expect((await vinculos())['mb:inv:b'], mbMetaReservaPk);
      expect((await vinculos()).containsKey('mb:inv:cc-pp1'), false);
    });

    test('aplicação que já tem outra meta não é puxada para a Reserva', () async {
      await mbGarantirReserva();
      await database.into(database.objectives).insert(ObjectivesCompanion.insert(
          objectivePk: const Value('meta-x'),
          type: const Value(ObjectiveType.goal),
          name: 'Viagem',
          amount: 100,
          order: 5,
          walletFk: const Value('0'),
          dateTimeModified: Value(DateTime(2026, 11, 1))));
      await _aplicacao('mb:inv:a', 10);
      await mbDefinirAplicacoesDaMeta('meta-x', {'mb:inv:a'});
      await mbVincularAplicacoesNovas();
      expect(await vinculos(), {'mb:inv:a': 'meta-x'});
    });
  });
}
