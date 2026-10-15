import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const tenants = ast.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "TenantsPanel");
const functionText = name => tenants.body.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === name).getText(ast);
const fields = ["name", "dni", "phone", "email", "address", "notes"];

test("tenant editing scopes every field and renews its scope when opened", () => {
  const text = tenants.getText(ast);
  assert.ok(text.includes("setTenantFieldScope(crypto.randomUUID())"));
  for (const name of fields) assert.ok(text.includes(`autoComplete="off" name={tenantFieldName(\`${name}\`)}`));
});

test("scoped editing preserves contact identity, values and error handling", async () => {
  for (const result of [true, "No se pudo guardar"]) {
    const saved = [], closed = [], errors = [];
    const values = { name: "Ana Perez", dni: "12345678", phone: "1234", email: "ana@example.com", address: "Calle 1", notes: "Nota" };
    await vm.runInNewContext(`${functionText("tenantFieldName")}\n${functionText("submitTenant")}\nsubmitTenant({preventDefault(){},currentTarget:{}});`, {
      tenantFieldScope: "test", editingTenant: { id: "contact-id", name: "Nombre anterior", leaseCount: 2 },
      FormData: class { get(key) { return `  ${values[key.replace("tenant-test-", "")]}  `; } },
      onSaveTenant: async payload => { saved.push(payload); return result; },
      setEditingTenant: value => closed.push(value), setSaveError: value => errors.push(value),
    });
    assert.deepEqual(JSON.parse(JSON.stringify(saved[0])), { id: "contact-id", oldName: "Nombre anterior", leaseCount: 2, ...values });
    assert.equal(closed.length, result === true ? 1 : 0);
    if (result !== true) assert.equal(errors.at(-1), result);
  }
});
