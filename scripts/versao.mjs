// Incrementa a versão (PATCH) no package.json e grava no index.html antes de cada deploy.
import { readFileSync, writeFileSync } from "node:fs";

const RE_VERSAO = /<span id="versao">[^<]*<\/span>/;
const html = readFileSync("public/index.html", "utf8");
if (!RE_VERSAO.test(html)) throw new Error('public/index.html sem <span id="versao">');

const pkg = JSON.parse(readFileSync("package.json", "utf8"));
const [a, b, c] = pkg.version.split(".").map(Number);
pkg.version = `${a}.${b}.${c + 1}`;
writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");

const quando = new Intl.DateTimeFormat("pt-BR", {
  timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit",
}).format(new Date()).replace(",", "");
writeFileSync("public/index.html", html.replace(RE_VERSAO, `<span id="versao">v${pkg.version} · ${quando}</span>`));
console.log(`Versão v${pkg.version} · ${quando}`);
