// Prints do app web (build em /app/) com Playwright: 1280 e 390, claro e escuro, mais detalhe e busca no desktop.
// Pré-requisitos: `pnpm dev` na porta 8787 com D1 local semeado (veja .claude/skills/verificar-app-web/SKILL.md) e o build web em public/app.
// Uso: pnpm prints   (saída em apps/worker/.prints/; erros de console, violações de CSP e falhas de rede vão para o terminal)
import { chromium } from "playwright";
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const aqui = dirname(fileURLToPath(import.meta.url));
const saida = join(aqui, "..", ".prints");
const base = process.env.PRINTS_BASE || "http://localhost:8787";
const senha = readFileSync(join(aqui, "..", ".dev.vars"), "utf8").match(/^APP_PASSWORD=(.*)$/m)?.[1]?.trim();
if (!senha) throw new Error("APP_PASSWORD ausente em .dev.vars");

// Primeira linha da tabela "Últimas transações" no 1280 (CanvasKit: clique por posição). Ajuste via PRINTS_LINHA="x,y".
const [linhaX, linhaY] = (process.env.PRINTS_LINHA || "640,470").split(",").map(Number);
const tamanhos = [{ w: 1280, h: 800 }, { w: 390, h: 844 }];
const temas = ["light", "dark"];
const pausa = (ms) => new Promise((r) => setTimeout(r, ms));
const problemas = [];
// Conhecido e inofensivo: o plugin google_sign_in_web injeta accounts.google.com/gsi/client ao registrar; a CSP do /app/ bloqueia de propósito.
const conhecidos = [/accounts\.google\.com\/gsi\/client/];

async function cookieDeSessao() {
  const r = await fetch(`${base}/api/login`, {
    method: "POST",
    headers: { "content-type": "application/json", origin: base },
    body: JSON.stringify({ senha }),
  });
  if (!r.ok) throw new Error(`login falhou (${r.status})`);
  const valor = r.headers.get("set-cookie")?.split(";")[0];
  const i = valor.indexOf("=");
  return { name: valor.slice(0, i), value: valor.slice(i + 1), url: base };
}

function vigiar(page, rotulo) {
  page.on("console", (m) => {
    if (["error", "warning"].includes(m.type())) problemas.push(`[${rotulo}] console.${m.type()}: ${m.text().slice(0, 300)}`);
  });
  page.on("pageerror", (e) => problemas.push(`[${rotulo}] pageerror: ${String(e).slice(0, 300)}`));
  page.on("requestfailed", (r) => problemas.push(`[${rotulo}] requestfailed: ${r.url()} ${r.failure()?.errorText}`));
  page.on("response", (r) => {
    if (r.status() >= 400) problemas.push(`[${rotulo}] HTTP ${r.status()}: ${r.url()}`);
  });
}

async function abrir(browser, cookie, { w, h }, tema, extra = {}) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, colorScheme: tema, locale: "pt-BR", timezoneId: "America/Sao_Paulo", ...extra });
  await ctx.addCookies([cookie]);
  const page = await ctx.newPage();
  vigiar(page, `${w}-${tema}${extra.reducedMotion ? "-rm" : ""}`);
  const sincronizou = page.waitForResponse((r) => r.url().includes("/api/sync") && r.request().method() === "GET", { timeout: 30000 }).catch(() => null);
  await page.goto(`${base}/app/`);
  await page.waitForSelector("flt-glass-pane", { state: "attached", timeout: 30000 });
  await sincronizou; // o Drift web começa vazio em cada contexto: espera o pull antes das animações
  return { ctx, page };
}

mkdirSync(saida, { recursive: true });
const browser = await chromium.launch({ args: ["--enable-unsafe-swiftshader"] });
const cookie = await cookieDeSessao();
for (const tam of tamanhos) {
  for (const tema of temas) {
    const { ctx, page } = await abrir(browser, cookie, tam, tema);
    await pausa(Number(process.env.PRINTS_ESPERA || 6000));
    await page.screenshot({ path: join(saida, `app-${tam.w}-${tema}.png`) });
    if (tam.w === 1280) {
      await page.mouse.click(linhaX, linhaY);
      await pausa(600);
      await page.screenshot({ path: join(saida, `app-1280-${tema}-detalhe.png`) });
      await page.keyboard.press("Control+K");
      await pausa(600);
      await page.screenshot({ path: join(saida, `app-1280-${tema}-busca.png`) });
    }
    // Sem animação: recarrega no mesmo contexto (o banco local já tem os dados) e tira o print logo após o carregamento.
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.reload();
    await page.waitForSelector("flt-glass-pane", { state: "attached", timeout: 30000 });
    await pausa(500);
    await page.screenshot({ path: join(saida, `app-${tam.w}-${tema}-semanimacao.png`) });
    await ctx.close();
  }
}
await browser.close();
const relevantes = problemas.filter((p) => !conhecidos.some((c) => c.test(p)));
console.log(problemas.join("\n") || "sem mensagens");
console.log(`\n${relevantes.length} problema(s) de console/CSP/rede (fora o conhecido do gsi/client); prints em ${saida}`);
process.exitCode = relevantes.length ? 1 : 0;
