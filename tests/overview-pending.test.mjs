import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";
import { roundPaymentAmount } from "../lib/urban-payment-amounts.ts";
import { argentinaDay as realArgentinaDay } from "../lib/argentina-day.ts";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const functions = new Map(ast.statements.filter(ts.isFunctionDeclaration).map(node => [node.name.text, node]));
const overview = functions.get("O");
const helpers = ["T", "x", "previousExpensePeriod", "chargeTotal", "E", "monthlyRentUpdateDate", "rentUpdateDateFor", "leaseUpdateDates", "normalizeDateInput", "parseDateParts", "daysInMonth", "addMonths", "G", "firstOfMonthDate"].map(name => functions.get(name).getText(ast)).join("\n");
const months = ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre"];

function pending(props, date = "2026-10-15T12:00:00-03:00") {
  return vm.runInNewContext(`${helpers}\nfunction pending(${overview.parameters.map(node => node.getText(ast)).join(",")}){${overview.body.statements[0].getText(ast)}return {period,overdueCharges,unliquidatedBuildings,pendingReviewCount}}\npending(props)`, {
    props: { units: [], ...props }, p: months, roundPaymentAmount, argentinaDay: () => realArgentinaDay(new Date(date)),
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

function updateDates(unit, month) {
  return vm.runInNewContext(`${helpers}
    ({overview:monthlyRentUpdateDate(unit,month),billing:rentUpdateDateFor(unit,month+'-'+String(unit.dueDay).padStart(2,'0'))})`,{unit,month});
}

const lease={id:"mauro",status:"Alquilado",dueDay:10,leaseStart:"2026-03-15",leaseEnd:"2028-03-14",updateFrequencyMonths:4,nextUpdate:"2026-11-15"};

test("legacy day-15 adjustments apply on the first of the same month in both views",()=>{
  const november=updateDates(lease,"2026-11");
  assert.equal(november.overview,"2026-11-01");assert.equal(november.billing,november.overview);
  const december=updateDates(lease,"2026-12");
  assert.equal(december.overview,"2026-11-01");assert.equal(december.billing,december.overview);
});

test("adjustments before or on the due date and carried-over adjustments agree in both views",()=>{
  for(const nextUpdate of ["2026-11-01","2026-11-10","2026-10-15"]){
    const result=updateDates({...lease,nextUpdate},"2026-11");
    assert.equal(result.overview,result.billing);assert.ok(result.overview);
  }
  const january=updateDates({...lease,nextUpdate:"2026-12-15"},"2027-01");
  assert.equal(january.overview,"2026-12-01");assert.equal(january.billing,january.overview);
});

test("inactive contracts, dates outside the lease and already advanced updates never flag rent",()=>{
  for(const unit of [
    {...lease,status:"Disponible"}, {...lease,nextUpdate:""},
    {...lease,nextUpdate:"2026-12-15"}, {...lease,nextUpdate:"2028-04-01"},
    {...lease,leaseEnd:"2026-11-05",nextUpdate:"2026-11-01"},
    {...lease,leaseStart:"2026-11-20",nextUpdate:"2026-11-20"},
  ]){
    const result=updateDates(unit,"2026-11");
    assert.equal(result.overview,"");assert.equal(result.billing,"");
  }
});

test("overview pending adjustments use the rent due date and retain overdue adjustments",()=>{
  for(const [nextUpdate,count] of [["2026-11-15",1],["2026-11-10",1],["2026-10-15",1],["2026-12-15",0]]){
    const result=pending({buildings:[{id:"building",hasExpenses:false}],units:[{...lease,buildingId:"building",nextUpdate}]},"2026-11-01T12:00:00-03:00");
    assert.equal(result.pendingReviewCount,count);
  }
});

test("cards, department amount and collection rows call the shared adjustment rule",()=>{
  assert.match(overview.getText(ast),/updateDue=!!monthlyRentUpdateDate\(unit,o\)/);
  const collection=functions.get("k").getText(ast);
  assert.match(collection,/return rentUpdateDateFor\(unit, charge.dueDate\)/);
  assert.match(source,/amountOutdated=!!monthlyRentUpdateDate\(e,argentinaDay\(\).slice\(0,7\)\)/);
});

test("new and subsequent adjustment schedules use day one without shifting the adjustment month",()=>{
  const schedule=(start,end,frequency)=>Array.from(vm.runInNewContext(`${helpers};leaseUpdateDates(start,end,frequency)`,{start,end,frequency}));
  assert.deepEqual(schedule("2026-03-15","2027-04-14",4),["2026-07-01","2026-11-01","2027-03-01"]);
  assert.deepEqual(schedule("2027-01-31","2027-05-30",1),["2027-02-01","2027-03-01","2027-04-01","2027-05-01"]);
  assert.deepEqual(schedule("2023-10-31","2024-02-01",4),["2024-02-01"]);
  assert.deepEqual(schedule("2026-03-15","2026-06-30",4),[]);
  for(const frequency of [0,-1,1.5])assert.deepEqual(schedule("2026-03-15","2027-04-14",frequency),[]);
  assert.equal(vm.runInNewContext(`${helpers};G("2026-11-15",4)`),"2027-03-01");
});
