// Evolução mensal dos investimentos: um retrato por mês (mês civil em America/Sao_Paulo) com o saldo de cada aplicação.
// O retrato do mês corrente é refeito a cada sincronização; ao virar o mês ele fica congelado com a última leitura.
// Formato guardado (snapshot `investimentos_mensal`): { "2026-11": [{ id, nome, banco, saldo }] }.

export const CHAVE_HISTORICO = "investimentos_mensal";
const TZ = "America/Sao_Paulo";

// "2026-11" do instante dado, no fuso de São Paulo.
export const mesSP = (data = new Date()) => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(data).slice(0, 7);

// Devolve o histórico com o retrato de `mes` trocado por `lista` (meses anteriores intactos).
// Quem chama só grava com aplicações na leitura: um mês vazio por falha de leitura apagaria um retrato bom.
export function registrarRetrato(historico, lista, mes) {
  const base = historico && typeof historico === "object" && !Array.isArray(historico) ? historico : {};
  return { ...base, [mes]: lista.map(({ id, nome, banco, saldo }) => ({ id, nome, banco, saldo })) };
}

// Série para o app, do mês mais antigo ao mais recente.
export function serieMensal(historico) {
  return Object.keys(historico || {}).sort().map((mes) => ({ mes, itens: historico[mes] }));
}
