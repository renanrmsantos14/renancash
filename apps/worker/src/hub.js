// Durable Object com WebSocket (Hibernation API): só repassa avisos, não guarda dados.
// O Worker chama POST /avisar depois de cada gravação; os clientes respondem puxando o espelho.
export class EspelhoHub {
  constructor(ctx) {
    this.ctx = ctx;
    // O "ping" do cliente é respondido sem acordar o objeto (não conta como requisição de DO).
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    if (request.headers.get("upgrade") === "websocket") {
      const [cliente, servidor] = Object.values(new WebSocketPair());
      this.ctx.acceptWebSocket(servidor);
      return new Response(null, { status: 101, webSocket: cliente });
    }
    const aviso = await request.text();
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.send(aviso); } catch { /* socket já fechado: o runtime o remove */ }
    }
    return new Response(null, { status: 204 });
  }

  webSocketMessage() {} // o cliente só ouve; mensagens dele (fora o ping) são ignoradas

  webSocketClose(ws, codigo) {
    ws.close([1005, 1006, 1015].includes(codigo) ? 1000 : codigo); // 1005, 1006 e 1015 são reservados: não podem ser enviados
  }
}
