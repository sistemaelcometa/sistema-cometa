import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const modal = ast.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "PdeReservationModal");
const functionText = name => modal.body.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === name).getText(ast);

test("reservation fields disable autocomplete and have per-opening names", () => {
  const text = modal.getText(ast);
  assert.ok(text.includes("crypto.randomUUID()"));
  assert.ok(text.includes('className="modal-form" autoComplete="off"'));
  for (const name of ["unit", "guest", "from", "to", "total", "depositDate", "paid"]) {
    assert.ok(text.includes(`autoComplete="off" name={fieldName(\`${name}\`)}`));
  }
});

for (const editing of [false, true]) {
  test(`scoped reservation fields preserve ${editing ? "editing" : "new reservation and deposit"} data`, () => {
    const saved = [], values = new Map([["test-guest", "  Ana Perez  "], ["test-unit", "601"]]);
    vm.runInNewContext(`${functionText("fieldName")}\n${functionText("submit")}\nsubmit({preventDefault(){},currentTarget:{}});`, {
      fieldScope: "test", FormData: class { get(key) { return values.get(key); } },
      units: ["602"], reservation: editing ? { id: "existing" } : null,
      from: "2027-01-10", to: "2027-01-20", totalAmount: 2000, paidAmount: 500,
      paysDeposit: true, depositDate: "2026-10-15", status: "Parcial", onSave: value => saved.push(value),
    });
    assert.equal(saved.length, 1);
    assert.equal(saved[0].guest, "Ana Perez");
    assert.equal(saved[0].unit, "601");
    assert.equal(saved[0].total, 2000);
    assert.equal(saved[0].paid, 500);
    assert.equal(saved[0].from, "2027-01-10");
    assert.equal(saved[0].to, "2027-01-20");
    assert.equal(saved[0].depositDate, editing ? null : "2026-10-15");
    if (editing) assert.equal(saved[0].id, "existing");
  });
}
