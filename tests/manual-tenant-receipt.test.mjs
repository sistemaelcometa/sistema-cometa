import assert from "node:assert/strict";
import test from "node:test";
import { PDFDocument } from "pdf-lib";
import { buildManualTenantReceipt, manualReceiptFilename, manualReceiptPeriodLabel } from "../lib/manual-tenant-receipt.ts";

const receipt = {
  tenantName: "José Pérez", documentNumber: "12345678", location: "DPTO 3 - EDIFICIO EJEMPLO",
  concept: "Saldo de expensas", period: "2026-09", amount: 37971.41,
  currency: "ARS", issuedAt: "2026-10-14", dueAt: "2026-10-20",
};

test("a historical tenant expense balance creates a readable, single-page PDF", async () => {
  const bytes = await buildManualTenantReceipt(receipt);
  const pdf = await PDFDocument.load(bytes);
  assert.equal(pdf.getPageCount(), 1);
  assert.equal(pdf.getTitle(), "Comprobante de saldo - José Pérez - Septiembre 2026");
  assert.equal(pdf.getSubject(), "Saldo de expensas - Septiembre 2026");
  assert.equal(manualReceiptFilename(receipt), "comprobante-expensas-jose-perez-2026-09.pdf");
});

test("a new tenant rent-only balance supports dollars and no due date", async () => {
  const rent = { ...receipt, concept: "Saldo de alquiler", period: "2026-10", amount: 500, currency: "USD", dueAt: "" };
  const pdf = await PDFDocument.load(await buildManualTenantReceipt(rent));
  assert.equal(pdf.getPageCount(), 1);
  assert.equal(pdf.getSubject(), "Saldo de alquiler - Octubre 2026");
  assert.equal(manualReceiptFilename(rent), "comprobante-alquiler-jose-perez-2026-10.pdf");
});

test("long names, unbroken text and observations wrap into valid pages", async () => {
  const pdf = await PDFDocument.load(await buildManualTenantReceipt({ ...receipt,
    tenantName: "Apellido".repeat(24), detail: "Descripción".repeat(27), notes: "Observación extensa. ".repeat(150),
  }));
  assert.ok(pdf.getPageCount() >= 1);
  assert.ok(pdf.getPages().every(page => page.getHeight() === 842));
});

test("invalid dates, periods and balances cannot produce misleading receipts", async () => {
  assert.equal(manualReceiptPeriodLabel("2026-09"), "Septiembre 2026");
  for (const invalid of [
    { tenantName: "" }, { amount: 0 }, { amount: -1 }, { amount: NaN },
    { period: "2026-13" }, { issuedAt: "2026-02-31" }, { dueAt: "2026-04-31" },
    { currency: "EUR" }, { concept: "Cobro registrado" }, { concept: "Otro saldo", detail: "" },
  ]) await assert.rejects(buildManualTenantReceipt({ ...receipt, ...invalid }));
});
