// Incrementa a versão (PATCH) no package.json e grava nos HTMLs e no service worker antes de cada deploy.
import { readFileSync, writeFileSync } from "node:fs";

const RE_VERSAO = /<span id="versao">[^<]*<\/span>/;
const PAGINAS = ["public/index.html", "public/login.html"];
const htmls = PAGINAS.map((p) => [p, readFileSync(p, "utf8")]);
for (const [p, html] of htmls) if (!RE_VERSAO.test(html)) throw new Error(`${p} sem <span id="versao">`);
const RE_SW = /const VERSAO = "[^"]*";/;
const sw = readFileSync("public/sw.js", "utf8");
if (!RE_SW.test(sw)) throw new Error('public/sw.js sem const VERSAO = "...";');

const pkg = JSON.parse(readFileSync("package.json", "utf8"));
const [a, b, c] = pkg.version.split(".").map(Number);
pkg.version = `${a}.${b}.${c + 1}`;
writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");

const quando = new Intl.DateTimeFormat("pt-BR", {
  timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit",
}).format(new Date()).replace(",", "");
for (const [p, html] of htmls) writeFileSync(p, html.replace(RE_VERSAO, `<span id="versao">v${pkg.version} · ${quando}</span>`));
writeFileSync("public/sw.js", sw.replace(RE_SW, `const VERSAO = "v${pkg.version}";`));
console.log(`Versão v${pkg.version} · ${quando}`);
