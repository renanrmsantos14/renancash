// src/ia.js — sugestões de categoria para a aba Pendências do app, com Workers AI (binding AI, plano gratuito).
//
// A IA nunca aplica nada: devolve uma sugestão que o usuário confirma, corrige ou explica no app.
// O app manda o contexto (categorias, empréstimos/metas e exemplos de respostas dele); o modelo vê só códigos curtos
// (C1, S3, V2) e o Worker os troca pelos pks. Código que não existe no contexto é descartado.
// Qualquer falha (sem binding, modelo removido, limite do plano, timeout) devolve `ia: false`: o app segue sem IA e
// mostra "Sem IA agora". Resposta fora do formato só descarta as sugestões (`ia: true`, lista vazia).
// Nada de descrição ou valor vai para o log.

// Na lista de JSON mode da doc do Workers AI e no catálogo atual, sem data de remoção. O @cf/meta/llama-3.1-8b-instruct
// saiu do catálogo (toda chamada falhava e o app recebia lista vazia).
export const MODELO = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
export const MAX_LANCAMENTOS = 8;
const MAX_CATEGORIAS = 80;
const MAX_SUBS = 30;
const MAX_VINCULOS = 30;
const MAX_EXEMPLOS = 20;
const MAX_TEXTO = 120;
const MAX_EXPLICACAO = 300;
const MAX_TITULO = 40;
const MAX_PERGUNTA = 140;
export const LIMIAR_PERGUNTA = 0.7; // abaixo disso a sugestão vem com pergunta
const TIMEOUT_MS = 15000;

const texto = (v, max) => (typeof v === "string" ? v.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, max) : "");
const lista = (v, max) => (Array.isArray(v) ? v.slice(0, max) : []);

// Contexto do app → códigos curtos para o prompt e o caminho de volta (código → pk).
export function montarContexto(ctx) {
  const cats = new Map(); // C1 → { pk, nome, receita, subs: Map(S1 → { pk, nome }) }
  const subs = new Map(); // S1 → { pk, cat: "C1" }
  const vinculos = new Map(); // V1 → { pk, nome, tipo }
  const porPk = new Map(); // pk → código (exemplos chegam com pks)
  let s = 0;
  for (const c of lista(ctx?.categorias, MAX_CATEGORIAS)) {
    const nome = texto(c?.nome, 40);
    if (typeof c?.pk !== "string" || !nome) continue;
    const cod = "C" + (cats.size + 1);
    const filhos = new Map();
    for (const f of lista(c.subs, MAX_SUBS)) {
      const n = texto(f?.nome, 40);
      if (typeof f?.pk !== "string" || !n) continue;
      const sc = "S" + ++s;
      filhos.set(sc, { pk: f.pk, nome: n });
      subs.set(sc, { pk: f.pk, cat: cod });
      porPk.set(f.pk, sc);
    }
    cats.set(cod, { pk: c.pk, nome, receita: c.receita === true, subs: filhos });
    porPk.set(c.pk, cod);
  }
  for (const v of lista(ctx?.vinculos, MAX_VINCULOS)) {
    const nome = texto(v?.nome, 40);
    if (typeof v?.pk !== "string" || !nome || !["emprestimo", "meta"].includes(v.tipo)) continue;
    const cod = "V" + (vinculos.size + 1);
    vinculos.set(cod, { pk: v.pk, nome, tipo: v.tipo });
    porPk.set(v.pk, cod);
  }
  const exemplos = [];
  for (const e of lista(ctx?.exemplos, MAX_EXEMPLOS)) {
    const cat = porPk.get(e?.categoria);
    const descricao = texto(e?.descricao, MAX_TEXTO);
    if (!cat?.startsWith("C") || !descricao) continue;
    const sub = porPk.get(e.subcategoria);
    const vin = porPk.get(e.vinculo);
    exemplos.push({ descricao, cat, sub: subs.get(sub)?.cat === cat ? sub : "", titulo: texto(e.titulo, MAX_TITULO), vin: vin?.startsWith("V") ? vin : "" });
  }
  return { cats, subs, vinculos, exemplos };
}

function lancamento(l) {
  const valor = Number(l?.valor);
  if (typeof l?.id !== "string" || !Number.isFinite(valor)) return null;
  return { id: l.id, descricao: texto(l.descricao, MAX_TEXTO), valor, data: texto(l.data, 10), conta: texto(l.conta, 40), categoria: texto(l.categoria, 40) };
}

export const lancamentosValidos = (v) => lista(v, MAX_LANCAMENTOS).map(lancamento).filter(Boolean);

const brl = (v) => (v < 0 ? "-" : "") + "R$ " + Math.abs(v).toFixed(2).replace(".", ",");

const SISTEMA = [
  "Você classifica lançamentos bancários de uma pessoa no Brasil. Responda só com JSON no formato pedido.",
  "Para cada lançamento escolha: categoria (um código C), subcategoria (um código S que esteja dentro dessa categoria, ou \"\"),",
  "titulo curto em português (2 a 4 palavras, sem nome de banco e sem 'Pix', ex.: 'Almoço', 'Uber', 'Empréstimo Mãe'),",
  "vinculo (código V) só se o lançamento for claramente dinheiro emprestado, devolvido ou guardado para aquela meta, senão \"\",",
  `confianca de 0 a 1 e, se a confianca for menor que ${LIMIAR_PERGUNTA}, uma pergunta curta (até 100 caracteres) que cite o valor e o favorecido,`,
  "ex.: 'Esse Pix de R$ 500 para Fabiana foi empréstimo para a Mãe?'. Com confianca alta, pergunta = \"\".",
  "Valor negativo é saída de dinheiro: use categoria de despesa. Os exemplos são respostas do próprio usuário:",
  "mesmo favorecido ou mesma descrição leva à mesma escolha, com confianca alta. Nunca invente códigos.",
].join(" ");

function blocoContexto({ cats, vinculos, exemplos }) {
  const linhas = ["Categorias:"];
  for (const [cod, c] of cats) {
    const filhos = [...c.subs].map(([sc, f]) => `${sc} ${f.nome}`).join(", ");
    linhas.push(`${cod} ${c.nome} (${c.receita ? "receita" : "despesa"})${filhos ? ": " + filhos : ""}`);
  }
  if (vinculos.size) {
    linhas.push("Vínculos:");
    for (const [cod, v] of vinculos) linhas.push(`${cod} ${v.tipo === "emprestimo" ? "Empréstimo" : "Meta"}: ${v.nome}`);
  }
  if (exemplos.length) {
    linhas.push("Exemplos do usuário (descrição → escolha):");
    for (const e of exemplos) linhas.push(`"${e.descricao}" → ${[e.cat, e.sub, e.vin].filter(Boolean).join(" ")}${e.titulo ? ` título "${e.titulo}"` : ""}`);
  }
  return linhas.join("\n");
}

const linhaLancamento = (l, n) =>
  `${n}. ${l.data || "sem data"} | ${l.conta || "conta"} | ${brl(l.valor)} | "${l.descricao || "sem descrição"}"${l.categoria ? ` | categoria atual: ${l.categoria}` : ""}`;

export function promptSugerir(ctxMontado, lancamentos) {
  return [
    { role: "system", content: SISTEMA },
    { role: "user", content: `${blocoContexto(ctxMontado)}\n\nLançamentos (n = número da linha):\n${lancamentos.map((l, i) => linhaLancamento(l, i + 1)).join("\n")}` },
  ];
}

export function promptEntender(ctxMontado, l, explicacao) {
  return [
    { role: "system", content: SISTEMA + " Agora o usuário explicou um lançamento com as palavras dele: interprete o que ele quis dizer e devolva essa classificação (n = 1). Explicação clara = confianca alta e pergunta vazia." },
    { role: "user", content: `${blocoContexto(ctxMontado)}\n\nLançamento:\n${linhaLancamento(l, 1)}\n\nExplicação do usuário: "${texto(explicacao, MAX_EXPLICACAO)}"` },
  ];
}

export const ESQUEMA = {
  type: "object",
  properties: {
    sugestoes: {
      type: "array",
      items: {
        type: "object",
        properties: {
          n: { type: "integer" },
          categoria: { type: "string" },
          subcategoria: { type: "string" },
          titulo: { type: "string" },
          vinculo: { type: "string" },
          confianca: { type: "number" },
          pergunta: { type: "string" },
        },
        required: ["n", "categoria", "subcategoria", "titulo", "vinculo", "confianca", "pergunta"],
      },
    },
  },
  required: ["sugestoes"],
};

// Uma sugestão do modelo → estrutura do app (pks), ou null se a categoria não existir ou não servir ao sinal do valor.
export function validarSugestao(bruta, ctxMontado, l) {
  const cat = ctxMontado.cats.get(texto(bruta?.categoria, 8).toUpperCase());
  if (!cat || (l.valor < 0 && cat.receita)) return null;
  const sub = cat.subs.get(texto(bruta.subcategoria, 8).toUpperCase());
  const vinculo = ctxMontado.vinculos.get(texto(bruta.vinculo, 8).toUpperCase());
  const c = Number(bruta.confianca);
  const confianca = Number.isFinite(c) ? Math.min(1, Math.max(0, c > 1 && c <= 100 ? c / 100 : c)) : 0;
  const pergunta = confianca < LIMIAR_PERGUNTA ? texto(bruta.pergunta, MAX_PERGUNTA) : "";
  return {
    id: l.id,
    categoria: cat.pk,
    subcategoria: sub?.pk ?? null,
    titulo: texto(bruta.titulo, MAX_TITULO) || null,
    vinculo: vinculo?.pk ?? null,
    confianca: Math.round(confianca * 100) / 100,
    pergunta: pergunta || null,
  };
}

// Saída do modelo (objeto já parseado ou texto, às vezes com cercas ```) → sugestões válidas, uma por lançamento no máximo.
export function lerResposta(resposta, ctxMontado, lancamentos) {
  let r = resposta;
  if (typeof r === "string") {
    try {
      r = JSON.parse(r.replace(/^\s*```(?:json)?|```\s*$/g, ""));
    } catch {
      return [];
    }
  }
  const out = new Map();
  for (const s of lista(r?.sugestoes, MAX_LANCAMENTOS * 2)) {
    const l = lancamentos[Number(s?.n) - 1];
    if (!l || out.has(l.id)) continue;
    const v = validarSugestao(s, ctxMontado, l);
    if (v) out.set(l.id, v);
  }
  return [...out.values()];
}

async function rodar(ai, mensagens, maxTokens) {
  let timer;
  const limite = new Promise((_, rej) => (timer = setTimeout(() => rej(new Error("timeout")), TIMEOUT_MS)));
  try {
    const r = await Promise.race([
      ai.run(MODELO, { messages: mensagens, response_format: { type: "json_schema", json_schema: ESQUEMA }, max_tokens: maxTokens, temperature: 0.2 }),
      limite,
    ]);
    return r?.response;
  } finally {
    clearTimeout(timer);
  }
}

// Falha da IA vira null. O log leva só o tipo do erro (nunca prompt, descrição ou valor).
async function seguro(fn) {
  try {
    return await fn();
  } catch (e) {
    console.error("IA indisponível:", e?.name || "Erro", String(e?.message || "").slice(0, 80));
    return null;
  }
}

// POST /api/ia/sugerir { contexto, lancamentos[] } → { sugestoes[] }
export async function sugerir(env, corpo) {
  const lancamentos = lancamentosValidos(corpo?.lancamentos);
  if (!env.AI || !lancamentos.length) return { sugestoes: [], ia: Boolean(env.AI) };
  const ctx = montarContexto(corpo?.contexto);
  if (!ctx.cats.size) return { sugestoes: [], ia: true };
  const sugestoes = await seguro(async () => lerResposta(await rodar(env.AI, promptSugerir(ctx, lancamentos), 110 * lancamentos.length + 60), ctx, lancamentos));
  return { sugestoes: sugestoes ?? [], ia: sugestoes !== null };
}

// POST /api/ia/entender { contexto, lancamento, explicacao } → { sugestao | null }
export async function entender(env, corpo) {
  const [l] = lancamentosValidos([corpo?.lancamento]);
  const explicacao = texto(corpo?.explicacao, MAX_EXPLICACAO);
  if (!env.AI || !l || !explicacao) return { sugestao: null, ia: Boolean(env.AI) };
  const ctx = montarContexto(corpo?.contexto);
  if (!ctx.cats.size) return { sugestao: null, ia: true };
  const sugestoes = await seguro(async () => lerResposta(await rodar(env.AI, promptEntender(ctx, l, explicacao), 200), ctx, [l]));
  return { sugestao: sugestoes?.[0] ?? null, ia: sugestoes !== null };
}
