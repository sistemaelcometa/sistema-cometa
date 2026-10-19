import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("PDE legend indicators match the elements targeted by the calendar colors", async () => {
  const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
  const css = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
  assert.ok(source.includes('<i className={colors[unit]} aria-hidden="true" />'));
  assert.match(css, /\.pde-legend i\s*\{[^}]*width:\s*16px;[^}]*height:\s*9px;/);
  assert.match(css, /\.pde-legend i\.pde-lane-one\s*\{[^}]*background:\s*linear-gradient/);
  assert.match(css, /\.pde-legend i\.pde-lane-two\s*\{[^}]*background:\s*linear-gradient/);
});
