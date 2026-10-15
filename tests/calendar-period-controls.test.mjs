import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/calendar-period-controls.tsx", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, target: ts.ScriptTarget.ES2020,
} }).outputText;
const exports = {};
vm.runInNewContext(compiled, { exports, require, Date });
const months = Array.from({ length: 12 }, (_, index) => `Month ${index}`);

function controls(date) {
  let changed;
  const tree = exports.CalendarPeriodControls({ value: date, onChange: value => { changed = value; }, months });
  const nodes = [];
  function visit(node) {
    if (!node || typeof node !== "object") return;
    nodes.push(node);
    for (const child of [node.props?.children].flat(Infinity)) visit(child);
  }
  visit(tree);
  return { find: label => nodes.find(node => node.props?.["aria-label"] === label), getChanged: () => changed };
}

test("month arrows cross year boundaries and reset the day to one", () => {
  const december = controls(new Date(2026, 11, 31));
  december.find("Mes siguiente").props.onClick();
  assert.equal(december.getChanged().getFullYear(), 2027);
  assert.equal(december.getChanged().getMonth(), 0);
  assert.equal(december.getChanged().getDate(), 1);
  const january = controls(new Date(2027, 0, 31));
  january.find("Mes anterior").props.onClick();
  assert.equal(january.getChanged().getFullYear(), 2026);
  assert.equal(january.getChanged().getMonth(), 11);
});

test("year arrows preserve the selected month, including leap years", () => {
  const controlsForLeapYear = controls(new Date(2024, 1, 29));
  controlsForLeapYear.find("Año siguiente").props.onClick();
  assert.equal(controlsForLeapYear.getChanged().getFullYear(), 2025);
  assert.equal(controlsForLeapYear.getChanged().getMonth(), 1);
  controlsForLeapYear.find("Año anterior").props.onClick();
  assert.equal(controlsForLeapYear.getChanged().getFullYear(), 2023);
});

test("both dropdowns remain usable", () => {
  const calendar = controls(new Date(2026, 9, 15));
  calendar.find("Mes").props.onChange({ target: { value: "2" } });
  assert.equal(calendar.getChanged().getMonth(), 2);
  assert.equal(calendar.getChanged().getFullYear(), 2026);
  calendar.find("Año").props.onChange({ target: { value: "2030" } });
  assert.equal(calendar.getChanged().getFullYear(), 2030);
  assert.equal(calendar.getChanged().getMonth(), 9);
});

test("arrows respect the existing year range", () => {
  const first = controls(new Date(2020, 0, 1));
  assert.equal(first.find("Mes anterior").props.disabled, true);
  assert.equal(first.find("Año anterior").props.disabled, true);
  assert.equal(first.find("Mes siguiente").props.disabled, false);
  const last = controls(new Date(2040, 11, 1));
  assert.equal(last.find("Mes siguiente").props.disabled, true);
  assert.equal(last.find("Año siguiente").props.disabled, true);
});
