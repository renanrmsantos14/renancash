import { test } from "node:test";
import assert from "node:assert/strict";
import { alertasCredito } from "../src/alertas.js";

test("rotativo, fatura parcelada e anuidade recentes viram aviso; o resto não", () => {
  const t = (id, tipo, date, extra = {}) => ({ id, tipo_credito: tipo, date, amount: 45.9, ...extra });
  const a = alertasCredito({ hoje: "2026-11-18", transacoes: [
    t("r", "REVOLVING_CREDIT", "2026-11-15"), t("p", "BILL_INSTALLMENT", "2026-11-10"), t("f", "ANNUAL_FEE", "2026-11-18"),
    t("velho", "ANNUAL_FEE", "2026-10-01"), t("outro", "OTHER", "2026-11-18"), t("fut", "ANNUAL_FEE", "2026-12-18", { scheduled: 1 }),
  ] });
  assert.deepEqual(a.map((x) => [x.chave, x.titulo]), [["credito:r", "Cartão no rotativo"], ["credito:p", "Fatura parcelada"], ["credito:f", "Anuidade cobrada"]]);
  assert.match(a[2].corpo, /R\$\s45,90 em 18\/11/);
});
