// Protocolo de sincronização dos dados do usuário (tabela genérica `registros` no D1).
// Last-write-wins por registro pelo `updated_at` do cliente; o cursor de leitura usa o `server_at` do servidor.

export type Tabela = "categorias" | "regras" | "orcamentos" | "limites" | "metas" | "dividas" | "assinaturas" | "ajustes" | "lancamentos" | "revisoes" | "carteiras" | "configuracoes";

export interface Registro {
  tabela: Tabela;
  id: string;
  dados: Record<string, unknown> | null;
  updated_at: string;
  deleted_at: string | null;
}

type Campo = "texto" | "json" | "numero" | "lista" | "data" | readonly (string | number)[];
type Esquema = Readonly<Record<string, Campo>>; // chave terminada em "?" = opcional (ausente ou null); chaves extras são aceitas

export const TABELAS: Readonly<Record<Tabela, Esquema>> = {
  categorias: { nome: "texto", tipo: ["despesa", "receita"], "cor?": "texto", "icone?": "texto", "pai_id?": "texto", "ordem?": "numero", "pluggy?": "lista" },
  regras: { padrao: "texto", categoria_id: "texto", "conta_id?": "texto", "prioridade?": "numero" },
  // arquivado: orçamento arquivado no app (continua existindo). limite_absoluto: os limites por categoria são valores em vez de percentuais.
  orcamentos: { nome: "texto", valor: "numero", categoria_ids: "lista", periodo: ["ciclo", "mensal"], "arquivado?": [0, 1], "limite_absoluto?": [0, 1] },
  // Limite de uma categoria dentro de um orçamento; `valor` é percentual ou valor absoluto conforme `limite_absoluto` do orçamento.
  limites: { orcamento_id: "texto", categoria_id: "texto", valor: "numero" },
  // valor_alvo 0 = meta sem valor definido. aplicacao_ids: ids das aplicações (Pluggy) que compõem a meta; cada aplicação em uma meta só.
  metas: { nome: "texto", valor_alvo: "numero", "valor_atual?": "numero", "prazo?": "data", "aplicacao_ids?": "lista" },
  dividas: { tipo: ["emprestimo"], nome: "texto", "pessoa?": "texto", sentido: ["devo", "me_devem"], valor_total: "numero", "pago?": "numero" },
  assinaturas: { nome: "texto", valor: "numero", dia: "numero", padrao: "texto", status: ["confirmada", "ignorada"], "categoria_id?": "texto" },
  // nome/nota: título e nota editados numa transação do banco (`mb:`); sem eles vale o texto do banco.
  ajustes: { "category?": "texto", "gasto?": [0, 1], "categoria_id?": "texto", "nota?": "texto", "nome?": "texto" },
  // Fila "Para revisar": tipo "decisao" (id `tx:<transação>`) guarda a resposta do usuário; tipo "destinatario" (id `dest:<nome>`)
  // lembra a categoria do Pix enviado a essa pessoa. "reembolso" liga o Pix recebido ao gasto (`reembolso_de`); "troco" liga o Pix enviado
  // à mesma pessoa ao reembolso que ele abate (`troco_de` = id do Pix recebido). valor/data/descricao ficam na decisão para a lista de empréstimos não depender da transação.
  // Empréstimo: "emprestimo" leva a `pessoa` e, para somar a um empréstimo que já existe, `emprestimo_id` (id da decisão que o abriu; sem ele a
  // própria decisão abre um). "devolucao" com `emprestimo_id` abate esse empréstimo (sem ele, abate o mais antigo em aberto, como antes);
  // `sobra` (reais) é a parte do Pix que passou do saldo, com destino em `sobra_para` ("emprestimo" + `sobra_id`, "reembolso" + `reembolso_de`, "renda").
  // tipo "perdao" (id `perdao:<emprestimo_id>`): o saldo (`valor`) perdoado em `data` vira gasto nesse dia e sai do aberto.
  // `recategorizado`: o item "empréstimo sem pessoa" da fila foi resolvido recolocando a categoria da transação.
  revisoes: { tipo: ["decisao", "destinatario", "perdao"], "tx_id?": "texto", "destinatario?": "texto", "resposta?": ["categoria", "emprestimo", "investimento", "ajuda", "devolucao", "reembolso", "renda", "troco"], "categoria_id?": "texto", "reembolso_de?": "texto", "troco_de?": "texto", "pessoa?": "texto", "emprestimo_id?": "texto", "sobra?": "numero", "sobra_para?": ["emprestimo", "reembolso", "renda"], "sobra_id?": "texto", "recategorizado?": [0, 1], "valor?": "numero", "data?": "data", "descricao?": "texto" },
  // Uma configuração do app que afeta dados e cálculos (id = nome da chave); `valor` é o JSON do valor.
  configuracoes: { valor: "json" },
  carteiras: { nome: "texto", "cor?": "texto", "icone?": "texto", "ordem?": "numero", "moeda?": "texto", "decimais?": "numero" },
  // Agendada/recorrente: `tipo` + estado (pago, pulado, proxima_criada = já gerou a ocorrência seguinte, que tem id previsível `<id>::predict::<n>`),
  // despago = o usuário desmarcou o pagamento (sem ele, `pago: 0` não desfaz uma ocorrência paga),
  // repetição (repeticao/periodo/fim) e `vencimento` (dia em que venceu; `data` passa a ser o dia do pagamento).
  lancamentos: {
    data: "data", descricao: "texto", valor: "numero", "categoria_id?": "texto", "carteira?": "texto", "nota?": "texto",
    "tipo?": ["agendada", "recorrente"], "pago?": [0, 1], "despago?": [0, 1], "pulado?": [0, 1], "proxima_criada?": [0, 1],
    "repeticao?": ["diaria", "semanal", "mensal", "anual", "personalizada"], "periodo?": "numero", "fim?": "data", "vencimento?": "data",
  },
};

export const MAX_LOTE = 500;
export const MAX_DADOS = 8192;
export const FOLGA_RELOGIO_MS = 5 * 60_000;
export const SOBREPOSICAO_MS = 2 * 60_000;

const DATA = /^\d{4}-\d{2}-\d{2}$/;

function campoValido(tipo: Campo, v: unknown): boolean {
  if (Array.isArray(tipo)) return (tipo as readonly unknown[]).includes(v);
  if (tipo === "texto") return typeof v === "string" && v.length > 0 && v.length <= 200;
  if (tipo === "json") return typeof v === "string" && v.length > 0 && v.length <= 4000; // valor serializado (listas e mapas de configuração)
  if (tipo === "numero") return typeof v === "number" && Number.isFinite(v);
  if (tipo === "lista") return Array.isArray(v) && v.every((x) => typeof x === "string");
  return typeof v === "string" && DATA.test(v);
}

export function dadosValidos(tabela: Tabela, dados: unknown): boolean {
  if (!dados || typeof dados !== "object" || Array.isArray(dados)) return false;
  const d = dados as Record<string, unknown>;
  return Object.entries(TABELAS[tabela]).every(([nome, tipo]) => {
    const opcional = nome.endsWith("?");
    const v = d[opcional ? nome.slice(0, -1) : nome];
    return (opcional && v == null) || campoValido(tipo, v);
  });
}

const iso = (v: unknown): string | null => {
  if (typeof v !== "string") return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : new Date(t).toISOString();
};

function problema(bruto: unknown): string | null {
  if (!bruto || typeof bruto !== "object") return "registro inválido";
  const r = bruto as Record<string, unknown>;
  if (typeof r.tabela !== "string" || !Object.hasOwn(TABELAS, r.tabela)) return "tabela desconhecida";
  if (typeof r.id !== "string" || r.id.length < 1 || r.id.length > 80) return "id inválido";
  if (!iso(r.updated_at)) return "updated_at inválido";
  if (r.deleted_at != null) return iso(r.deleted_at) ? null : "deleted_at inválido";
  if (!dadosValidos(r.tabela as Tabela, r.dados)) return "dados inválidos";
  if (JSON.stringify(r.dados).length > MAX_DADOS) return "dados acima de 8 KB";
  return null;
}

export type Rejeitado = { indice: number; motivo: string };

export function validarLote(entrada: unknown, agora: string): { registros: Registro[]; rejeitados: Rejeitado[] } | { erro: string } {
  if (!Array.isArray(entrada)) return { erro: "registros deve ser uma lista" };
  if (entrada.length > MAX_LOTE) return { erro: `no máximo ${MAX_LOTE} registros por envio` };
  const limite = Date.parse(agora) + FOLGA_RELOGIO_MS;
  const corrigir = (v: string) => (Date.parse(v) > limite ? agora : v); // relógio adiantado não vence para sempre
  const registros: Registro[] = [];
  const rejeitados: Rejeitado[] = [];
  entrada.forEach((bruto, indice) => {
    const motivo = problema(bruto);
    if (motivo) return void rejeitados.push({ indice, motivo });
    const r = bruto as Registro;
    const deleted = r.deleted_at == null ? null : corrigir(iso(r.deleted_at) as string);
    registros.push({ tabela: r.tabela, id: r.id, dados: deleted ? null : r.dados, updated_at: corrigir(iso(r.updated_at) as string), deleted_at: deleted });
  });
  return { registros, rejeitados };
}

export const chave = (r: Pick<Registro, "tabela" | "id">): string => `${r.tabela}:${r.id}`;

// Empate fica com o que já existe: o mesmo registro reenviado não muda nada.
export const vence = (novo: Registro, atual: Registro | undefined): boolean => !atual || novo.updated_at > atual.updated_at;

export function mesclar(local: ReadonlyMap<string, Registro>, remotos: readonly Registro[]): Map<string, Registro> {
  const saida = new Map(local);
  for (const r of remotos) if (vence(r, saida.get(chave(r)))) saida.set(chave(r), r);
  return saida;
}

// O pull relê 2 min antes do cursor: uma gravação que terminou logo depois do `agora` anterior não se perde.
export function inicioDaJanela(desde: string | null): string | null {
  return desde === null ? null : new Date(Date.parse(desde) - SOBREPOSICAO_MS).toISOString();
}

// ---------- Espelho completo (tabela `espelho` no D1): a linha inteira do app em JSON ----------

// Mesma lista no app (budget/lib/struct/mbSync/espelho.dart). `_config` é a entidade virtual das configurações (pk = chave).
export const TABELAS_ESPELHO = [
  "wallets", "transactions", "categories", "category_budget_limits", "associated_titles", "budgets", "scanner_templates", "objectives",
  "mb_orcamento_tx", "mb_meta_aplicacao", "mb_revisoes", "_config",
] as const;
export type TabelaEspelho = (typeof TABELAS_ESPELHO)[number];

export const MAX_LINHA_ESPELHO = 16 * 1024;
export const MAX_PK_ESPELHO = 200;

export interface LinhaEspelho {
  tabela: TabelaEspelho;
  pk: string;
  dados: Record<string, unknown> | null;
  updated_at: string;
  deleted_at: string | null;
}

export type LinhaRejeitada = { tabela: string; pk: string; motivo: string };

function problemaLinha(bruto: unknown): string | null {
  if (!bruto || typeof bruto !== "object") return "linha inválida";
  const l = bruto as Record<string, unknown>;
  if (typeof l.tabela !== "string" || !(TABELAS_ESPELHO as readonly string[]).includes(l.tabela)) return "tabela fora da allowlist";
  if (typeof l.pk !== "string" || l.pk.length < 1 || l.pk.length > MAX_PK_ESPELHO) return "pk inválida";
  if (!iso(l.updated_at)) return "updated_at inválido";
  if (l.deleted_at != null) return iso(l.deleted_at) ? null : "deleted_at inválido";
  if (!l.dados || typeof l.dados !== "object" || Array.isArray(l.dados)) return "dados ausentes sem deleted_at";
  if (new TextEncoder().encode(JSON.stringify(l.dados)).length > MAX_LINHA_ESPELHO) return "linha acima de 16 KB";
  return null;
}

// Mesma regra do `validarLote`: data do futuro (além da folga) vira agora; exclusão leva `dados` nulos.
export function validarLinhasEspelho(entrada: unknown, agora: string): { linhas: LinhaEspelho[]; rejeitados: LinhaRejeitada[] } | { erro: string } {
  if (!Array.isArray(entrada)) return { erro: "linhas deve ser uma lista" };
  if (entrada.length > MAX_LOTE) return { erro: `no máximo ${MAX_LOTE} linhas por envio` };
  const limite = Date.parse(agora) + FOLGA_RELOGIO_MS;
  const corrigir = (v: string) => (Date.parse(v) > limite ? agora : v);
  const linhas: LinhaEspelho[] = [];
  const rejeitados: LinhaRejeitada[] = [];
  for (const bruto of entrada) {
    const motivo = problemaLinha(bruto);
    const l = bruto as Record<string, unknown> | null;
    if (motivo) {
      rejeitados.push({ tabela: String(l?.tabela ?? ""), pk: String(l?.pk ?? ""), motivo });
      continue;
    }
    const x = bruto as LinhaEspelho;
    const deleted = x.deleted_at == null ? null : corrigir(iso(x.deleted_at) as string);
    linhas.push({ tabela: x.tabela, pk: x.pk, dados: deleted ? null : x.dados, updated_at: corrigir(iso(x.updated_at) as string), deleted_at: deleted });
  }
  return { linhas, rejeitados };
}
