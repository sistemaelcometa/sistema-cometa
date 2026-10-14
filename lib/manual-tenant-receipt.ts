import type { PDFFont } from "pdf-lib";

export const manualReceiptConcepts = ["Saldo de expensas", "Saldo de alquiler", "Otro saldo"] as const;

export type ManualTenantReceipt = {
  tenantName: string;
  documentNumber?: string;
  location?: string;
  concept: (typeof manualReceiptConcepts)[number];
  period: string;
  detail?: string;
  amount: number;
  currency: "ARS" | "USD";
  issuedAt: string;
  dueAt?: string;
  notes?: string;
};

const months = ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre"];

export function manualReceiptPeriodLabel(period: string): string {
  const match = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(period);
  if (!match) throw new Error("Seleccioná el mes del saldo.");
  return `${months[Number(match[2]) - 1]} ${match[1]}`;
}

function dateLabel(value: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) throw new Error("Revisá la fecha del comprobante.");
  const date = new Date(`${value}T12:00:00Z`);
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) {
    throw new Error("Revisá la fecha del comprobante.");
  }
  return `${match[3]}/${match[2]}/${match[1]}`;
}

function printableText(value: string, font: PDFFont): string {
  return Array.from(value.normalize("NFC").replace(/[\u0000-\u001f]/g, " "))
    .map(char => {
      try { font.encodeText(char); return char; } catch { return "?"; }
    }).join("");
}

function wrapText(text: string, font: PDFFont, size: number, width: number): string[] {
  const lines: string[] = [];
  let line = "";
  for (const word of printableText(text, font).split(/\s+/).filter(Boolean)) {
    const candidate = line ? `${line} ${word}` : word;
    if (font.widthOfTextAtSize(candidate, size) <= width) { line = candidate; continue; }
    if (line) { lines.push(line); line = ""; }
    for (const char of word) {
      if (font.widthOfTextAtSize(line + char, size) > width && line) { lines.push(line); line = ""; }
      line += char;
    }
  }
  if (line) lines.push(line);
  return lines;
}

export function manualReceiptFilename(receipt: ManualTenantReceipt): string {
  const tenant = receipt.tenantName.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 70) || "inquilino";
  const concept = receipt.concept === "Saldo de expensas" ? "expensas" : receipt.concept === "Saldo de alquiler" ? "alquiler" : "saldo";
  return `comprobante-${concept}-${tenant}-${receipt.period}.pdf`;
}

export async function buildManualTenantReceipt(receipt: ManualTenantReceipt): Promise<Uint8Array> {
  if (!receipt.tenantName.trim()) throw new Error("Seleccioná un inquilino.");
  if (!manualReceiptConcepts.includes(receipt.concept)) throw new Error("Seleccioná el concepto del saldo.");
  if (receipt.concept === "Otro saldo" && !receipt.detail?.trim()) throw new Error("Ingresá el detalle del saldo.");
  if (!Number.isFinite(receipt.amount) || Math.round(receipt.amount * 100) <= 0) throw new Error("Ingresá un importe mayor a cero.");
  if (!["ARS", "USD"].includes(receipt.currency)) throw new Error("Revisá la moneda del saldo.");
  const period = manualReceiptPeriodLabel(receipt.period);
  const issuedAt = dateLabel(receipt.issuedAt);
  const dueAt = receipt.dueAt ? dateLabel(receipt.dueAt) : "";
  const { PDFDocument, StandardFonts, rgb } = await import("pdf-lib");
  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let page = pdf.addPage([595, 842]);
  let y = 800;
  const left = 48, right = 547, width = right - left;

  function line() {
    page.drawLine({ start: { x: left, y }, end: { x: right, y }, thickness: 0.7, color: rgb(0.65, 0.65, 0.65) });
    y -= 22;
  }
  function text(value: string, size = 11, isBold = false, maxWidth = width) {
    const font = isBold ? bold : regular;
    for (const row of wrapText(value, font, size, maxWidth)) {
      if (y < 65) { page = pdf.addPage([595, 842]); y = 800; }
      page.drawText(row, { x: left, y, size, font, color: rgb(0, 0, 0) });
      y -= size + 7;
    }
  }

  text(period.toUpperCase(), 17, true);
  text("COMPROBANTE DE SALDO", 15, true);
  line();
  if (receipt.location?.trim()) text(receipt.location.trim(), 12, true);
  text(`Inquilino: ${receipt.tenantName.trim()}`, 11, true);
  if (receipt.documentNumber?.trim()) text(`DNI: ${receipt.documentNumber.trim()}`);
  text(`Fecha de emisión: ${issuedAt}`);
  if (dueAt) text(`Vencimiento: ${dueAt}`);
  y -= 18;
  text("Detalle del saldo", 12, true);
  line();

  const amount = `${receipt.currency === "ARS" ? "$" : "USD"} ${new Intl.NumberFormat("es-AR", {
    minimumFractionDigits: 2, maximumFractionDigits: 2,
  }).format(Math.round(receipt.amount * 100) / 100)}`;
  const amountSize = Math.min(12, 150 / bold.widthOfTextAtSize(amount, 1));
  page.drawText(amount, { x: right - bold.widthOfTextAtSize(amount, amountSize), y, size: amountSize, font: bold });
  text(`${receipt.concept} - ${period}`, 11, true, width - 170);
  if (receipt.detail?.trim()) text(receipt.detail.trim(), 10, false, width - 170);
  y -= 20;
  line();
  page.drawText(amount, { x: right - bold.widthOfTextAtSize(amount, amountSize), y, size: amountSize, font: bold });
  text("Total a pagar", 13, true, width - 170);
  y -= 8;
  line();
  if (receipt.notes?.trim()) { text("Observaciones", 10, true); text(receipt.notes.trim(), 10); }

  pdf.setTitle(`Comprobante de saldo - ${receipt.tenantName.trim()} - ${period}`);
  pdf.setSubject(`${receipt.concept} - ${period}`);
  return pdf.save();
}
