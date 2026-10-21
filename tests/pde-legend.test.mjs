import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createRequire } from "node:module";
import vm from "node:vm";

test("PDE legend indicators match the elements targeted by the calendar colors", async () => {
  const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
  const css = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
  assert.ok(source.includes('<i className={colors[unit]} aria-hidden="true" />'));
  assert.match(css, /\.pde-legend i\s*\{[^}]*width:\s*16px;[^}]*height:\s*9px;/);
  assert.match(css, /\.pde-legend i\.pde-lane-one\s*\{[^}]*background:\s*linear-gradient/);
  assert.match(css, /\.pde-legend i\.pde-lane-two\s*\{[^}]*background:\s*linear-gradient/);
});

test("PDE calendar unit toggles default to visible and only filter calendar lanes", async () => {
  const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
  const require = createRequire(import.meta.url), ts = require("typescript");
  const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const calendar = ast.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "V");
  const toggle = calendar.body.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "toggleCalendarUnit");
  const declarations = calendar.body.statements.filter(ts.isVariableStatement).flatMap(node => Array.from(node.declarationList.declarations));
  const hidden = declarations.find(node => node.name.getText(ast).includes("hiddenCalendarUnits"));
  const visible = declarations.find(node => node.name.getText(ast) === "visibleCalendarUnits");
  assert.equal(hidden.initializer.getText(ast), "React.useState([])");
  let hiddenUnits = [];
  const toggleUnit = vm.runInNewContext(`${toggle.getText(ast)};toggleCalendarUnit`, {
    setHiddenCalendarUnits: update => { hiddenUnits = Array.from(update(hiddenUnits)); },
  });
  function visibleUnits() {
    return Array.from(vm.runInNewContext(visible.initializer.getText(ast), { units: ["209","601"], hiddenCalendarUnits: hiddenUnits }));
  }
  assert.deepEqual(visibleUnits(), ["209","601"]);
  toggleUnit("601"); assert.deepEqual(visibleUnits(), ["209"]);
  toggleUnit("209"); assert.deepEqual(visibleUnits(), []);
  toggleUnit("601"); assert.deepEqual(visibleUnits(), ["601"]);
  toggleUnit("209"); assert.deepEqual(visibleUnits(), ["209","601"]);
  assert.ok(source.includes('type="checkbox" checked={!hiddenCalendarUnits.includes(unit)}'));
  assert.ok(source.includes('aria-label={`Mostrar departamento ${unit}`}'));
  assert.ok(source.includes('}>{visibleCalendarUnits.map(unit=>'));
  assert.ok(source.includes('initialMonth={calendarMonth} units={units} reservations={e||[]}'));
});
