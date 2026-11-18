// Endereço antigo (meu-banco.*.workers.dev): o Worker virou "renancash". Tudo vai para o novo, mesmo caminho.
const NOVO = "https://renancash.renanrmsantos14.workers.dev";

export default {
  fetch(request) {
    const url = new URL(request.url);
    return new Response(null, { status: 308, headers: { location: NOVO + url.pathname + url.search, "cache-control": "no-store" } });
  },
};
