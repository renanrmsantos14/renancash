export interface TxCategoria { id: string; account_id: string; description: string | null; category: string | null }
export interface RegraCtx { id: string; padrao: string; categoria_id: string; conta_id?: string | null; prioridade?: number | null }
export interface ContextoCategoria {
  ajustes: ReadonlyMap<string, { categoria_id?: string | null; category?: string | null }>;
  regras: readonly RegraCtx[];
  pluggy: ReadonlyMap<string, string>;
  porNome: ReadonlyMap<string, string>;
}
export type Efetiva = { fonte: "ajuste" | "regra" | "pluggy" | "nome" | "banco"; categoria_id: string | null; category: string | null };

const escapar = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export function padraoCasa(padrao: string, texto: string): boolean {
  const p = padrao.trim();
  if (!p) return false;
  return new RegExp("^" + p.split("*").map(escapar).join(".*") + "$", "i").test((texto || "").trim());
}

export function ordenarRegras<T extends RegraCtx>(regras: readonly T[]): T[] {
  return [...regras].sort((a, b) => (b.prioridade ?? 0) - (a.prioridade ?? 0) || b.padrao.length - a.padrao.length || (a.id < b.id ? -1 : 1));
}

const porNome = (ctx: ContextoCategoria, nome: string, receita: boolean) => ctx.porNome.get(`${receita ? "receita" : "despesa"}:${nome.toLowerCase()}`) ?? null;

export function categoriaEfetiva(t: TxCategoria, ctx: ContextoCategoria, traduzir: (c: string | null) => string, receita: boolean): Efetiva {
  const a = ctx.ajustes.get(t.id);
  if (a?.categoria_id) return { fonte: "ajuste", categoria_id: a.categoria_id, category: null };
  if (a?.category) return { fonte: "ajuste", categoria_id: ctx.pluggy.get(a.category) ?? porNome(ctx, traduzir(a.category), receita), category: a.category };
  const r = ordenarRegras(ctx.regras).find((r) => (!r.conta_id || r.conta_id === t.account_id) && padraoCasa(r.padrao, t.description ?? ""));
  if (r) return { fonte: "regra", categoria_id: r.categoria_id, category: null };
  const m = t.category ? ctx.pluggy.get(t.category) : undefined;
  if (m) return { fonte: "pluggy", categoria_id: m, category: null };
  const n = porNome(ctx, traduzir(t.category), receita);
  return n ? { fonte: "nome", categoria_id: n, category: null } : { fonte: "banco", categoria_id: null, category: t.category };
}

export function contextoDeRegistros(regs: Iterable<{ tabela: string; id: string; dados: Record<string, unknown> | null; deleted_at: string | null }>): ContextoCategoria {
  const ajustes = new Map<string, { categoria_id?: string | null; category?: string | null }>();
  const regras: RegraCtx[] = [];
  const pluggy = new Map<string, string>();
  const nomes = new Map<string, string>();
  for (const r of regs) {
    if (r.deleted_at != null || !r.dados) continue;
    const d = r.dados;
    if (r.tabela === "ajustes") ajustes.set(r.id, d as { categoria_id?: string | null; category?: string | null });
    else if (r.tabela === "regras") regras.push({ id: r.id, padrao: String(d.padrao), categoria_id: String(d.categoria_id), conta_id: (d.conta_id as string | null | undefined) ?? null, prioridade: (d.prioridade as number | null | undefined) ?? null });
    else if (r.tabela === "categorias") {
      for (const p of Array.isArray(d.pluggy) ? (d.pluggy as string[]) : []) pluggy.set(p, r.id);
      nomes.set(`${d.tipo}:${String(d.nome).toLowerCase()}`, r.id);
    }
  }
  return { ajustes, regras, pluggy, porNome: nomes };
}
