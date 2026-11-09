// Protocolo de sincronização dos dados do usuário (tabela genérica `registros` no D1).
// Last-write-wins por registro pelo `updated_at` do cliente; o cursor de leitura usa o `server_at` do servidor.

export type Tabela = "categorias" | "regras" | "orcamentos" | "metas" | "dividas" | "assinaturas" | "ajustes" | "lancamentos";

export interface Registro {
  tabela: Tabela;
  id: string;
  dados: Record<string, unknown> | null;
  updated_at: string;
  deleted_at: string | null;
}

type Campo = "texto" | "numero" | "lista" | "data" | readonly (string | number)[];
type Esquema = Readonly<Record<string, Campo>>; // chave terminada em "?" = opcional (ausente ou null); chaves extras são aceitas

export const TABELAS: Readonly<Record<Tabela, Esquema>> = {
  categorias: { nome: "texto", tipo: ["despesa", "receita"], "cor?": "texto", "icone?": "texto", "pai_id?": "texto", "ordem?": "numero", "pluggy?": "lista" },
  regras: { padrao: "texto", categoria_id: "texto", "conta_id?": "texto", "prioridade?": "numero" },
  orcamentos: { nome: "texto", valor: "numero", categoria_ids: "lista", periodo: ["ciclo", "mensal"] },
  metas: { nome: "texto", valor_alvo: "numero", "valor_atual?": "numero", "prazo?": "data" },
  dividas: { tipo: ["emprestimo"], nome: "texto", "pessoa?": "texto", sentido: ["devo", "me_devem"], valor_total: "numero", "pago?": "numero" },
  assinaturas: { nome: "texto", valor: "numero", dia: "numero", padrao: "texto", status: ["confirmada", "ignorada"], "categoria_id?": "texto" },
  ajustes: { "category?": "texto", "gasto?": [0, 1], "categoria_id?": "texto", "nota?": "texto" },
  lancamentos: { data: "data", descricao: "texto", valor: "numero", "categoria_id?": "texto", "carteira?": "texto", "nota?": "texto" },
};

export const MAX_LOTE = 500;
export const MAX_DADOS = 8192;
export const FOLGA_RELOGIO_MS = 5 * 60_000;
export const SOBREPOSICAO_MS = 2 * 60_000;

const DATA = /^\d{4}-\d{2}-\d{2}$/;

function campoValido(tipo: Campo, v: unknown): boolean {
  if (Array.isArray(tipo)) return (tipo as readonly unknown[]).includes(v);
  if (tipo === "texto") return typeof v === "string" && v.length > 0 && v.length <= 200;
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
