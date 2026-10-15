import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";
import { roundPaymentAmount } from "../lib/urban-payment-amounts.ts";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const functions = new Map(ast.statements.filter(ts.isFunctionDeclaration).map(node => [node.name.text, node]));
const overview = functions.get("O");
const helpers = ["T", "x", "previousExpensePeriod", "chargeTotal", "E"].map(name => functions.get(name).getText(ast)).join("\n");
const months = ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre"];

function pending(props, date = "2026-10-15T12:00:00-03:00") {
  return vm.runInNewContext(`${helpers}\nfunction pending(${overview.parameters.map(node => node.getText(ast)).join(",")}){${overview.body.statements[0].getText(ast)}return {period,overdueCharges,unliquidatedBuildings,pendingReviewCount}}\npending(props)`, {
    props: { units: [], ...props }, p: months, roundPaymentAmount,
    React: { useState: value => [value, () => {}], useMemo: callback => callback() },
    Date: class extends Date { constructor(...args) { super(...(args.length ? args : [date])); } },
  });
}

test("overdue alerts exclude zero balances, paid charges and cancelled charges", () => {
  const charges = [
    { id: "zero", rent: 0 }, { id: "covered", rent: 100, paid: 100, status: "partial" },
    { id: "cancelled", rent: 100, status: "cancelled" }, { id: "paid", rent: 100, status: "paid" },
    { id: "future", rent: 100, dueDate: "2026-11-10" },
    { id: "partial", rent: 100, expenses: 20, paid: 100, status: "partial" },
    { id: "cents", rent: 100.41, paid: 100 },
  ].map(row => ({ status: "pending", dueDate: "2026-10-10", ...row }));
  const result = pending({ charges });
  assert.deepEqual(Array.from(result.overdueCharges, row => row.id), ["partial", "cents"]);
  assert.equal(result.pendingReviewCount, 2);
});

test("expense alerts use last month's liquidation status, including calculated zero", () => {
  const buildings = ["calculated-zero", "closed", "draft", "missing", "disabled"].map(id => ({ id, hasExpenses: id !== "disabled" }));
  const units = buildings.map(building => ({ id: `${building.id}-unit`, buildingId: building.id }));
  const result = pending({ buildings, units, expenseCalculations: {
    "calculated-zero::Septiembre 2026": { status: "calculated", totalExpenses: 0 },
    "closed::Septiembre 2026": { status: "closed" },
    "draft::Septiembre 2026": { status: "draft", totalExpenses: 500 },
    "missing::Octubre 2026": { status: "calculated" },
  } });
  assert.equal(result.period, "Septiembre 2026");
  assert.deepEqual(Array.from(result.unliquidatedBuildings, row => row.id), ["draft", "missing"]);
});

test("overview is clear when charges are covered and expenses calculated", () => {
  const result = pending({
    buildings: [{ id: "building" }], units: [{ id: "unit", buildingId: "building" }],
    charges: [{ dueDate: "2026-10-10", rent: 100, paid: 100, status: "partial" }],
    expenseCalculations: { "building::Septiembre 2026": { status: "calculated" } },
  });
  assert.equal(result.pendingReviewCount, 0);
});

test("January expense alerts refer to December of the prior year", () => {
  assert.equal(pending({}, "2027-01-15T12:00:00-03:00").period, "Diciembre 2026");
});
