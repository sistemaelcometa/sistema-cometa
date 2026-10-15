import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const lease = ast.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "M");
const functionText = name => lease.body.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === name).getText(ast);
const scopedFields = ["amount", "firstName", "lastName", "dni", "phone", "email", "address", "extra"];

test("lease form disables autocomplete and isolates remembered fields per opening", () => {
  const fields = new Map();
  function visit(node) {
    if (ts.isJsxSelfClosingElement(node) || ts.isJsxOpeningElement(node)) {
      const attributes = node.attributes.properties;
      const name = attributes.find(item => item.name?.text === "name")?.initializer?.getText(ast);
      const autocomplete = attributes.find(item => item.name?.text === "autoComplete")?.initializer?.getText(ast);
      if (name) fields.set(name, autocomplete);
      if (node.tagName.getText(ast) === "form") assert.equal(autocomplete, '"off"');
    }
    ts.forEachChild(node, visit);
  }
  visit(lease);
  for (const name of scopedFields) assert.equal(fields.get(`{fieldName(\`${name}\`)}`), '"off"');
  assert.ok(lease.getText(ast).includes("crypto.randomUUID()"));
});

for (const mode of ["new", "existing"]) {
  test(`scoped inputs preserve saved contract and ${mode} tenant data`, async () => {
    const scope = "lease-test-session", saved = [];
    const values = new Map(scopedFields.map(name => [`${scope}-${name}`, {
      amount: "950.000", firstName: "Ana", lastName: "Perez", dni: "12345678",
      phone: "1234", email: "ana@example.com", address: "Calle 1", extra: "Referencia",
    }[name]]));
    values.set("currency", "ARS"); values.set("dueDay", "10");
    values.set("contractNotes", "Detalle"); values.set("tenantNotes", "Observacion");
    values.set("existingTenant", "Existente"); values.set("contractPdf", "file.pdf");
    const existing = { name: "Existente", dni: "87654321" };
    await vm.runInNewContext(`${functionText("fieldName")}\n${functionText("submit")}\nsubmit({preventDefault(){},currentTarget:{}})`, {
      fieldScope: scope, isSaving: false, FormData: class { get(key) { return values.get(key); } },
      g: value => Number(String(value).replaceAll(".", "")), formatCurrency: amount => `$ ${amount}`,
      tenantNames: ["Existente"], tenantMode: mode, t: { Existente: existing },
      startDate: "2026-10-01", endDate: "2029-10-01", nextUpdate: "2027-02-01", frequency: "4",
      setSaveError() {}, setIsSaving() {}, a: async (...args) => { saved.push(args); return true; },
    });
    assert.equal(saved.length, 1);
    assert.equal(saved[0][0].leaseAmount, "$ 950000");
    assert.equal(saved[0][0].contractFile, "file.pdf");
    assert.equal(saved[0][0].detail, "Detalle");
    if (mode === "existing") assert.equal(saved[0][1], existing);
    else assert.deepEqual(JSON.parse(JSON.stringify(saved[0][1])), {
      name: "Ana Perez", dni: "12345678", phone: "1234", email: "ana@example.com",
      address: "Calle 1", extra: "Referencia", notes: "Observacion",
    });
  });
}
