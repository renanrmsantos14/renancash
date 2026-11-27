// Port de `mbCalcularEmprestimos` (budget/lib/struct/mbSync/emprestimos.dart): empréstimos em aberto a partir das decisões
// `emprestimo`/`devolucao` e dos perdões. É a MESMA regra do app: qualquer mudança aqui exige mudar o Dart (a fixture
// test/fixtures/emprestimos-paridade.json é executada pelos dois lados e quebra se divergirem). Tudo em centavos inteiros.

const dia = (d) => /^\d{4}-\d{2}-\d{2}/.exec(String(d ?? ""))?.[0] ?? null;
const centavos = (v) => (typeof v === "number" && Number.isFinite(v) ? Math.round(Math.abs(v) * 100) : 0);
const texto = (v) => (typeof v === "string" && v.trim() ? v.trim() : null);
export const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/** @returns {{abertos: object[], quitados: object[], devidoCentavos: number}} */
export function calcularEmprestimos(decisoes, perdoes = []) {
  const eventos = []; // tipo: 0 empréstimo, 1 devolução, 2 perdão (no mesmo dia, nessa ordem)
  for (const d of decisoes) {
    const resposta = d.resposta;
    const dd = dia(d.data);
    if ((resposta !== "emprestimo" && resposta !== "devolucao") || centavos(d.valor) === 0 || dd == null) continue;
    eventos.push({ dia: dd, tipo: resposta === "emprestimo" ? 0 : 1, chave: String(d.tx_id), d });
  }
  for (const p of perdoes) {
    const dd = dia(p.data);
    if (typeof p.emprestimo_id !== "string" || centavos(p.valor) === 0 || dd == null) continue;
    eventos.push({ dia: dd, tipo: 2, chave: p.emprestimo_id, d: p });
  }
  eventos.sort((a, b) => cmp(a.dia, b.dia) || a.tipo - b.tipo || cmp(a.chave, b.chave));

  const grupos = new Map();
  const abater = (g, c, txId, dd) => {
    const abate = Math.min(c, g.restante);
    if (abate <= 0) return;
    g.restante -= abate;
    g.pagamentos.push({ txId, data: dd, centavos: abate });
  };
  for (const e of eventos) {
    const d = e.d;
    if (e.tipo === 0) {
      const id = texto(d.emprestimo_id) ?? e.chave;
      if (!grupos.has(id)) grupos.set(id, { id, data: e.dia, pessoa: null, perdoadoEm: null, original: 0, restante: 0, perdoado: 0, pagamentos: [] });
      const g = grupos.get(id);
      const c = centavos(d.valor);
      g.original += c;
      g.restante += c;
      g.pessoa ??= texto(d.pessoa);
      if (cmp(e.dia, g.data) < 0) g.data = e.dia;
    } else if (e.tipo === 1) {
      const total = centavos(d.valor);
      const sobra = Math.min(centavos(d.sobra), total);
      const pagamento = total - sobra;
      const alvo = texto(d.emprestimo_id);
      if (alvo != null) {
        const g = grupos.get(alvo);
        if (g && g.perdoadoEm == null) abater(g, pagamento, e.chave, e.dia);
      } else {
        let falta = pagamento;
        const fila = [...grupos.values()].filter((g) => g.restante > 0 && g.perdoadoEm == null).sort((a, b) => cmp(`${a.data}${a.id}`, `${b.data}${b.id}`));
        for (const g of fila) {
          if (falta <= 0) break;
          const antes = g.restante;
          abater(g, falta, e.chave, e.dia);
          falta -= antes - g.restante;
        }
      }
      const destino = texto(d.sobra_id);
      if (sobra > 0 && d.sobra_para === "emprestimo" && destino != null) {
        const g = grupos.get(destino);
        if (g && g.perdoadoEm == null) abater(g, sobra, e.chave, e.dia);
      }
    } else {
      const g = grupos.get(e.chave);
      if (!g || g.perdoadoEm != null || g.restante === 0) continue;
      g.perdoado = g.restante;
      g.restante = 0;
      g.perdoadoEm = e.dia;
    }
  }
  const todos = [...grupos.values()].map((g) => ({
    txId: g.id, data: g.data, originalCentavos: g.original, restanteCentavos: g.restante, pessoa: g.pessoa,
    perdoadoCentavos: g.perdoado, perdoadoEm: g.perdoadoEm, pagoCentavos: g.original - g.restante - g.perdoado, pagamentos: g.pagamentos,
    aberto: g.restante > 0 && g.perdoadoEm == null,
  }));
  const antigo = (a, b) => cmp(`${a.data}${a.txId}`, `${b.data}${b.txId}`);
  const abertos = todos.filter((e) => e.aberto).sort(antigo);
  const quitados = todos.filter((e) => !e.aberto).sort((a, b) => antigo(b, a));
  return { abertos, quitados, devidoCentavos: abertos.reduce((s, e) => s + e.restanteCentavos, 0) };
}
