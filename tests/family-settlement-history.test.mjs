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
  const states = [], requests = [], fresh = { rows: [{ id: "saved-close" }], total: 1 };
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
    supabase: { rpc: async (name, args) => { requests.push({ name, args }); return { data: fresh, error: fail ? new Error("offline") : null }; } },
  });
  return { states, fresh, dependencies, cleanup, requests };
}

test("history refreshes when loaded settlements change and does not reuse stale empty history", async () => {
  const result = runEffect();
  assert.equal(result.dependencies[2], result.fresh.rows);
  assert.deepEqual(result.states, [null]);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(result.states.at(-1), result.fresh);
  assert.equal(result.states.length, 2);
  assert.equal(result.requests[0].args.status_filter, "current");
});

test("history contains only the current close per period, excluding reopened versions", () => {
  const normalizer = family.body.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === "normalizeSettlementRow");
  const rowsStatement = family.body.statements.find(node => ts.isVariableStatement(node)
    && node.declarationList.declarations.some(declaration => declaration.name.getText(ast) === "localSettlementRows"));
  const settlements = [
    { id: "old", period_start: "2026-10-01", period_end: "2026-10-31", version: 3, is_current: false, status: "cancelled" },
    { id: "reopened", period_start: "2026-10-01", period_end: "2026-10-31", version: 6, is_current: false, status: "cancelled" },
    { id: "current", period_start: "2026-10-01", period_end: "2026-10-31", version: 8, is_current: true, status: "closed" },
    { id: "september", periodStart: "2026-09-01", periodEnd: "2026-09-30", version: 1, isCurrent: true, statusKey: "closed" },
    { id: "corrected", period_start: "2026-09-01", period_end: "2026-09-30", version: 0, is_current: false, status: "corrected" },
  ];
  function visible(rows) {
    return vm.runInNewContext(`${normalizer.getText(ast)}\n${rowsStatement.getText(ast)}\n({settlementRows,settlementTotal});`, {
      settlements: rows, remoteSettlementsPage: null, settlementPageSize: 6, settlementPage: 1,
    });
  }
  const result = visible(settlements);
  assert.deepEqual(Array.from(result.settlementRows, row => row.id), ["current", "september"]);
  assert.equal(result.settlementTotal, 2);
  assert.equal(visible(settlements.filter(row => row.id !== "current" && row.id !== "september")).settlementTotal, 0);
  assert.equal(settlements.length, 5);
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
