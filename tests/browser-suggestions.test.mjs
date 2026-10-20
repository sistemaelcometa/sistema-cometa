import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const hook = ast.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "useDisableBrowserSuggestions");

test("global browser-suggestion defaults preserve explicitly disabled autocomplete", () => {
  function field(initial = {}) {
    const attrs = new Map(Object.entries(initial));
    return { getAttribute: key => attrs.get(key) ?? null, hasAttribute: key => attrs.has(key), setAttribute: (key, value) => attrs.set(key, value), attrs };
  }
  const amount = field({ type: "text", autocomplete: "off" });
  const unconfigured = field({ type: "text" });
  const date = field({ type: "date" });
  const attachment = field({ type: "file" });
  const form = field();
  let apply, disconnected = false, cleanup;
  vm.runInNewContext(`${hook.getText(ast)}\nuseDisableBrowserSuggestions();`, {
    React: { useEffect: callback => { cleanup = callback(); } },
    document: { body: {}, querySelectorAll: selector => selector === "form" ? [form] : [amount, unconfigured, date, attachment] },
    MutationObserver: class { constructor(callback) { apply = callback; } observe() {} disconnect() { disconnected = true; } },
  });
  assert.equal(amount.attrs.get("autocomplete"), "off");
  assert.equal(unconfigured.attrs.get("autocomplete"), "new-password");
  assert.equal(date.attrs.has("autocomplete"), false);
  assert.equal(attachment.attrs.has("autocomplete"), false);
  assert.equal(form.attrs.get("autocomplete"), "off");
  apply();
  assert.equal(amount.attrs.get("autocomplete"), "off");
  cleanup();
  assert.equal(disconnected, true);
});
