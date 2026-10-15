import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const family = ast.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "B");
const effect = family.body.statements.find(node => ts.isExpressionStatement(node)
  && ts.isCallExpression(node.expression) && node.expression.expression.getText(ast) === "React.useEffect");

function runEffect({ stale = true, fail = false } = {}) {
  const states = [], fresh = { rows: [{ id: "saved-close" }], total: 1 };
  let dependencies, cleanup;
  vm.runInNewContext(effect.getText(ast), {
    React: { useEffect(callback, deps) { dependencies = deps; cleanup = callback(); } },
    activeMembership: { organization_id: "organization" }, settlementPage: 1, settlementPageSize: 6,
    settlements: fresh.rows,
    setRemoteSettlementsPage: value => states.push(value),
    resourceCacheKey: () => "history",
    resourceCache: {
      get: () => ({ data: { rows: [], total: 0 } }),
      isStale: () => stale,
      hydrate: async (key, fetcher) => ({ data: await fetcher() }),
    },
    supabase: { rpc: async () => ({ data: fresh, error: fail ? new Error("offline") : null }) },
  });
  return { states, fresh, dependencies, cleanup };
}

test("history refreshes when loaded settlements change and does not reuse stale empty history", async () => {
  const result = runEffect();
  assert.equal(result.dependencies[2], result.fresh.rows);
  assert.deepEqual(result.states, [null]);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(result.states.at(-1), result.fresh);
  assert.equal(result.states.length, 2);
});

test("failed history refresh falls back to loaded settlements", async () => {
  const result = runEffect({ stale: false, fail: true });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(result.states.at(-1), null);
});

test("obsolete history requests cannot overwrite the next history view", async () => {
  const result = runEffect();
  result.cleanup();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(result.states, [null]);
});
