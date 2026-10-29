"use client";

import * as React from "react";
import { Download, Trash2 } from "lucide-react";
import { parsePdeExpenseAmount as parseAmount, formatPdeExpenseInput } from "@/lib/pde-expense-amounts";
import { formatPaymentCurrency } from "@/lib/urban-payment-amounts";

type Income = {
  id: string; date: string; unit: string; detail: string; amount: number;
  method?: string; receiptName?: string;
};
type IncomeInput = {
  date: string; unit: string; detail: string; amount: number; method: string;
  operationId: string; receiptFile: File | null;
};
const methods = { transfer: "Transferencia", cash: "Efectivo", deposit: "Depósito", card: "Tarjeta", other: "Otro" };
function dateLabel(value: string) { return value.split("-").reverse().join("/"); }

export function PdeMiscIncomeModal({ incomes = [], units, onClose, onSave, onDelete, onDownload }: {
  incomes?: Income[]; units: string[]; onClose: () => void;
  onSave: (input: IncomeInput) => Promise<true | string | { warning: string }>;
  onDelete: (id: string) => Promise<true | string>;
  onDownload: (income: Income) => void;
}) {
  const [tab, setTab] = React.useState("register");
  const [message, setMessage] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const [deleting, setDeleting] = React.useState<Income | null>(null);
  const [search, setSearch] = React.useState("");
  const [unit, setUnit] = React.useState("Todos");
  const [page, setPage] = React.useState(1);
  const [scope] = React.useState(() => `pde-income-${crypto.randomUUID()}`);
  const attempt = React.useRef<{ signature: string; id: string } | null>(null);
  const working = React.useRef(false);
  const today = new Date();
  const date = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
  const field = (name: string) => `${scope}-${name}`;
  const filtered = incomes.filter(item => (unit === "Todos" || item.unit === unit)
    && item.detail.toLowerCase().includes(search.trim().toLowerCase()))
    .sort((left, right) => right.date.localeCompare(left.date) || right.id.localeCompare(left.id));
  const pages = Math.max(1, Math.ceil(filtered.length / 8)), currentPage = Math.min(page, pages);
  const rows = filtered.slice((currentPage - 1) * 8, currentPage * 8);

  async function save(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (working.current) return;
    const form = event.currentTarget, data = new FormData(form);
    const amount = parseAmount(String(data.get(field("amount")) || ""));
    if (amount === null) {
      const input = form.elements.namedItem(field("amount")) as HTMLInputElement;
      input.setCustomValidity("Ingresá un importe mayor a cero, con hasta dos decimales.");
      input.reportValidity(); return;
    }
    const values = { date: String(data.get(field("date"))), unit: String(data.get(field("unit"))),
      detail: String(data.get(field("detail")) || "").trim(), amount, method: String(data.get(field("method"))) };
    if (!values.detail) { setMessage("El concepto es obligatorio."); return; }
    const signature = JSON.stringify(values);
    if (attempt.current?.signature !== signature) attempt.current = { signature, id: crypto.randomUUID() };
    const file = data.get(field("receipt")) as File | null;
    working.current = true; setBusy(true); setMessage("");
    try {
      const result = await onSave({ ...values, operationId: attempt.current.id, receiptFile: file?.name ? file : null });
      if (typeof result === "string") { setMessage(result); return; }
      attempt.current = null; form.reset(); setTab("history"); setPage(1);
      setMessage(result === true ? "Ingreso registrado." : result.warning);
    } catch (error) { setMessage(error instanceof Error ? error.message : "No se pudo registrar el ingreso."); }
    finally { working.current = false; setBusy(false); }
  }

  async function remove() {
    if (!deleting || working.current) return;
    working.current = true; setBusy(true); setMessage("");
    try {
      const result = await onDelete(deleting.id);
      if (result !== true) { setMessage(result); return; }
      setDeleting(null); setMessage("Ingreso anulado.");
    } catch (error) { setMessage(error instanceof Error ? error.message : "No se pudo anular el ingreso."); }
    finally { working.current = false; setBusy(false); }
  }

  return <div className="modal-backdrop stacked-modal" role="presentation">
    <section aria-modal="true" aria-label="Ingresos varios PDE" aria-busy={busy} className={`modal pde-modal pde-misc-income-modal ${tab === "history" ? "wide-modal" : ""}`} role="dialog">
      <div className="section-title"><div><h3>Ingresos varios</h3><p>Punta del Este</p></div>
        <button className="icon-button" type="button" disabled={busy} onClick={onClose} aria-label="Cerrar">X</button></div>
      <div className="segmented-control compact-segment" role="tablist" aria-label="Ingresos varios">
        <button type="button" role="tab" aria-selected={tab === "register"} className={tab === "register" ? "active" : ""} disabled={busy} onClick={() => { setTab("register"); setMessage(""); setDeleting(null); }}>Registrar</button>
        <button type="button" role="tab" aria-selected={tab === "history"} className={tab === "history" ? "active" : ""} disabled={busy} onClick={() => { setTab("history"); setMessage(""); }}>Historial</button>
      </div>
      {message && <p role="status" className="warning-box">{message}</p>}
      {tab === "register" ? <form className="modal-form" autoComplete="off" onSubmit={save}>
        <fieldset disabled={busy} className="pde-income-fields">
          <label>Fecha<input autoComplete="off" name={field("date")} type="date" defaultValue={date} required /></label>
          <label>Departamento<select autoComplete="off" name={field("unit")} defaultValue="General"><option value="General">General</option>{units.map(item => <option key={item}>{item}</option>)}</select></label>
          <label>Concepto<input autoComplete="off" name={field("detail")} type="text" maxLength={500} required /></label>
          <label>Importe USD<div className="money-input"><span aria-hidden="true">USD</span><input aria-label="Importe USD" autoComplete="off" name={field("amount")} type="text" inputMode="decimal" placeholder="0,00" required
            onInput={event => event.currentTarget.setCustomValidity("")}
            onBlur={event => { const amount = parseAmount(event.currentTarget.value); if (amount !== null) event.currentTarget.value = formatPdeExpenseInput(amount); }} /></div></label>
          <label>Medio de cobro<select autoComplete="off" name={field("method")} defaultValue="transfer">{Object.entries(methods).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></label>
          <label>Comprobante<input autoComplete="off" name={field("receipt")} type="file" accept=".pdf,.jpg,.jpeg,.png" /></label>
        </fieldset>
        <div className="modal-actions"><button className="secondary-button" type="button" disabled={busy} onClick={onClose}>Cancelar</button><button className="primary-button" type="submit" disabled={busy}>{busy ? "Guardando..." : "Guardar ingreso"}</button></div>
      </form> : <div className="pde-income-history">
        <div className="form-grid compact-form-grid"><label>Concepto<input autoComplete="off" type="search" value={search} onChange={event => { setSearch(event.target.value); setPage(1); }} /></label>
          <label>Departamento<select value={unit} onChange={event => { setUnit(event.target.value); setPage(1); }}><option>Todos</option><option>General</option>{units.map(item => <option key={item}>{item}</option>)}</select></label></div>
        {deleting && <div className="warning-box"><p>¿Anular el ingreso de {formatPaymentCurrency(deleting.amount, "USD")} por {deleting.detail}?</p><div className="inline-actions"><button className="secondary-button" type="button" disabled={busy} onClick={() => setDeleting(null)}>Cancelar</button><button className="primary-button" type="button" disabled={busy} onClick={remove}>{busy ? "Anulando..." : "Anular ingreso"}</button></div></div>}
        {!rows.length ? <p className="empty-state">No hay ingresos varios para esos filtros.</p> : <div className="responsive-table"><table><thead><tr><th>Fecha</th><th>Departamento</th><th>Concepto</th><th>Medio</th><th>Importe</th><th>Comprobante</th><th>Acciones</th></tr></thead>
          <tbody>{rows.map(item => <tr key={item.id}><td>{dateLabel(item.date)}</td><td>{item.unit}</td><td>{item.detail}</td><td>{methods[item.method as keyof typeof methods] || item.method || "-"}</td><td>{formatPaymentCurrency(item.amount, "USD")}</td>
            <td>{item.receiptName ? <button className="circle-icon-button" type="button" title="Descargar comprobante" aria-label="Descargar comprobante" onClick={() => onDownload(item)}><Download size={16} /></button> : "-"}</td>
            <td><button className="circle-icon-button danger-icon-button" type="button" disabled={busy} title="Anular ingreso" aria-label={`Anular ingreso ${item.detail}`} onClick={() => { setMessage(""); setDeleting(item); }}><Trash2 size={16} /></button></td></tr>)}</tbody></table></div>}
        <div className="table-pagination"><span>{filtered.length} ingresos · Página {currentPage} de {pages}</span>{pages > 1 && <div className="inline-actions"><button className="secondary-button compact-action" type="button" disabled={currentPage <= 1} onClick={() => setPage(currentPage - 1)}>Anterior</button><button className="secondary-button compact-action" type="button" disabled={currentPage >= pages} onClick={() => setPage(currentPage + 1)}>Siguiente</button></div>}</div>
      </div>}
    </section>
  </div>;
}
