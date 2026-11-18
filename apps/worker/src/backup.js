// Backup diário do D1 inteiro em JSON gzip no R2. Retenção de 30 dias: regra de ciclo de vida do bucket (não é código).
export async function exportarBanco(db) {
  const { results } = await db.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' AND name NOT LIKE 'd1\\_%' ESCAPE '\\' ORDER BY name"
  ).all();
  const lidas = await db.batch(results.map(({ name }) => db.prepare(`SELECT * FROM "${name.replaceAll('"', '""')}"`)));
  return { gerado_em: new Date().toISOString(), tabelas: Object.fromEntries(results.map(({ name }, i) => [name, lidas[i].results])) };
}

export const chaveBackup = (data) => `d1/${data.toISOString().slice(0, 10)}.json.gz`;

export async function salvarBackup(env, data) {
  const texto = JSON.stringify(await exportarBanco(env.DB));
  const gz = await new Response(new Blob([texto]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer();
  const chave = chaveBackup(data);
  await env.BACKUP.put(chave, gz, { httpMetadata: { contentType: "application/json", contentEncoding: "gzip" } });
  return chave;
}
