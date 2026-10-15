import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const functions = new Map();
function visit(node) {
  if (ts.isFunctionDeclaration(node)) functions.set(node.name?.text, node.getText(ast));
  ts.forEachChild(node, visit);
}
visit(ast);

test("opening the building form renews its field scope", () => {
  const scopes = [], opened = [];
  let counter = 0;
  vm.runInNewContext(`${functions.get("openBuildingForm")}\nopenBuildingForm();openBuildingForm();`, {
    crypto: { randomUUID: () => `session-${++counter}` },
    setBuildingFieldScope: value => scopes.push(value), setShowBuildingForm: value => opened.push(value),
  });
  assert.deepEqual(scopes, ["session-1", "session-2"]);
  assert.deepEqual(opened, [true, true]);
  assert.ok(source.includes('onClick={openBuildingForm}'));
  for (const field of ["name", "address"]) {
    assert.ok(source.includes(`autoComplete="off" name={buildingFieldName(\`${field}\`)}`));
  }
});

test("scoped building fields save name, address and expense setting", () => {
  const saved = [], closed = [], values = new Map([
    ["building-session-name", "  PELLEGRINI  "], ["building-session-address", "  Calle 571  "],
    ["hasExpenses", "on"],
  ]);
  vm.runInNewContext(`${functions.get("buildingFieldName")}\n${functions.get("submitBuilding")}\nsubmitBuilding({preventDefault(){},currentTarget:{}});`, {
    buildingFieldScope: "session", FormData: class { get(key) { return values.get(key); } },
    onAddBuilding: value => saved.push(value), setShowBuildingForm: value => closed.push(value),
  });
  assert.deepEqual(JSON.parse(JSON.stringify(saved)), [{ name: "PELLEGRINI", address: "Calle 571", hasExpenses: true }]);
  assert.deepEqual(closed, [false]);
});
