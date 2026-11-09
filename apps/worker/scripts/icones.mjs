// Gera os ícones PNG do app (cofre geométrico) sem dependências: node scripts/icones.mjs
import { mkdirSync, writeFileSync } from "node:fs";
import { deflateSync, crc32 } from "node:zlib";

const FUNDO = [255, 122, 0], CLARO = [255, 255, 255];

// Distância com sinal até um retângulo arredondado (negativo = dentro). Coordenadas de -0.5 a 0.5.
const caixa = (x, y, w, h, r) => Math.hypot(Math.max(Math.abs(x) - w / 2 + r, 0), Math.max(Math.abs(y) - h / 2 + r, 0)) + Math.min(Math.max(Math.abs(x) - w / 2 + r, Math.abs(y) - h / 2 + r), 0) - r;

// escala = tamanho do cofre em relação ao ícone (menor no "maskable", que o sistema recorta).
function cor(x, y, escala) {
  x /= escala; y /= escala;
  if (caixa(x, y, 0.8, 0.7, 0.12) <= 0) {
    const mostrador = Math.hypot(x, y);
    return mostrador < 0.2 && mostrador > 0.14 || mostrador < 0.06 ? FUNDO : CLARO;
  }
  const pe = Math.min(caixa(x - 0.25, y - 0.42, 0.14, 0.1, 0.03), caixa(x + 0.25, y - 0.42, 0.14, 0.1, 0.03));
  return pe <= 0 ? CLARO : FUNDO;
}

function png(tam, escala) {
  const S = 3, linhas = [];
  for (let py = 0; py < tam; py++) {
    const linha = Buffer.alloc(1 + tam * 3);
    for (let px = 0; px < tam; px++) {
      const soma = [0, 0, 0];
      for (let sy = 0; sy < S; sy++) for (let sx = 0; sx < S; sx++) {
        const c = cor((px + (sx + 0.5) / S) / tam - 0.5, (py + (sy + 0.5) / S) / tam - 0.5, escala);
        for (let i = 0; i < 3; i++) soma[i] += c[i];
      }
      for (let i = 0; i < 3; i++) linha[1 + px * 3 + i] = Math.round(soma[i] / (S * S));
    }
    linhas.push(linha);
  }
  const bloco = (tipo, dados) => {
    const b = Buffer.alloc(12 + dados.length);
    b.writeUInt32BE(dados.length, 0); b.write(tipo, 4, "ascii"); dados.copy(b, 8);
    b.writeUInt32BE(crc32(b.subarray(4, 8 + dados.length)), 8 + dados.length);
    return b;
  };
  const cab = Buffer.alloc(13);
  cab.writeUInt32BE(tam, 0); cab.writeUInt32BE(tam, 4); cab[8] = 8; cab[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), bloco("IHDR", cab), bloco("IDAT", deflateSync(Buffer.concat(linhas))), bloco("IEND", Buffer.alloc(0))]);
}

mkdirSync("public/icons", { recursive: true });
writeFileSync("public/icons/icon-192.png", png(192, 0.62));
writeFileSync("public/icons/icon-512.png", png(512, 0.62));
writeFileSync("public/icons/icon-maskable-512.png", png(512, 0.5));
writeFileSync("public/apple-touch-icon.png", png(180, 0.62));
console.log("Ícones gerados em public/");
