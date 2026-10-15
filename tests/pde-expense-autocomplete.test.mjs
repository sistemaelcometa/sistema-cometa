import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const modal = ast.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "PdeExpenseModal");
const functionText = name => modal.body.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === name).getText(ast);

test("expense form disables autocomplete and scopes its fields per opening", () => {
  const text = modal.getText(ast);
  assert.ok(text.includes("crypto.randomUUID()"));
  assert.ok(text.includes('className="modal-form" autoComplete="off"'));
  for (const name of ["unit", "date", "rubric", "amount", "detail", "receipt"]) {
    assert.ok(text.includes(`autoComplete="off" name={fieldName(\`${name}\`)}`));
  }
});

for (const attachment of [null, { name: "comprobante.pdf" }]) {
  test(`scoped expense inputs preserve amounts, department and ${attachment ? "attachment" : "no attachment"}`, () => {
    const saved = [], values = new Map([
      ["test-unit", "General"], ["test-date", "2026-10-15"], ["test-rubric", "Limpieza"],
      ["test-amount", "1.500"], ["test-detail", "  Limpieza mensual  "], ["test-receipt", attachment],
    ]);
    vm.runInNewContext(`${functionText("fieldName")}\n${functionText("submit")}\nsubmit({preventDefault(){},currentTarget:{}});`, {
      fieldScope: "test", units: ["601"], FormData: class { get(key) { return values.get(key); } },
      g: value => Number(String(value).replaceAll(".", "")), onSave: value => saved.push(value),
    });
    assert.equal(saved.length, 1);
    assert.equal(saved[0].unit, "General");
    assert.equal(saved[0].date, "2026-10-15");
    assert.equal(saved[0].rubric, "Limpieza");
    assert.equal(saved[0].amount, 1500);
    assert.equal(saved[0].detail, "Limpieza mensual");
    assert.equal(saved[0].receiptName, attachment?.name ?? "");
    assert.equal(saved[0].receiptFile, attachment);
  });
}
