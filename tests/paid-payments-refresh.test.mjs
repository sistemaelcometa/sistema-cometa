import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import test from "node:test";
import vm from "node:vm";
import { RuntimeResourceCache } from "../lib/resource-cache.ts";

const require = createRequire(import.meta.url), ts = require("typescript");
const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const ast = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const functions = new Map();
function visit(node) {
  if (ts.isFunctionDeclaration(node)) functions.set(node.name?.text, node);
  ts.forEachChild(node, visit);
}
visit(ast);
const effect = functions.get("k").body.statements.find(node => ts.isExpressionStatement(node)
  && node.getText(ast).includes("get_urban_payments_page"));
const helper = functions.get("markUrbanPaymentCachesStale").getText(ast);
const key = "urbanPaymentsPage:test";
const tick = () => new Promise(resolve => setImmediate(resolve));

function runEffect({ cache = new RuntimeResourceCache(), records = [], page = 1, data = { rows: [], total: 0 } } = {}) {
  const rows = [], pages = [], requests = [];
  let dependencies, cleanup;
  vm.runInNewContext(effect.getText(ast), {
    React: { useEffect(callback, deps) { dependencies = deps; cleanup = callback(); } },
    activeMembership: { organization_id: "org" }, tab: "paid", paidSearch: "", paidMonthFilter: 10,
    paidYearFilter: 2026, paidPage: page, paidPageSize: 10, paymentRecords: records,
    resourceCache: cache, resourceCacheKey: () => key,
    supabase: { rpc: async (name, args) => { requests.push(args); return { data, error: null }; } },
    setRemotePaidPage: value => rows.push(value), setPaidPage: value => pages.push(value),
    setPaidLoading() {}, setPaidRefreshing() {}, setPaidError() {},
  });
  return { rows, pages, requests, dependencies, cleanup };
}

test("paid history depends on payment records and discards stale cached rows", async () => {
  const cache = new RuntimeResourceCache(), records = [{ id: "remaining" }];
  await cache.hydrate(key, async () => ({ rows: [{ id: "deleted" }], total: 1 }));
  cache.markStale(key);
  const result = runEffect({ cache, records, data: { rows: records, total: 1 } });
  assert.equal(result.dependencies.at(-1), records);
  assert.deepEqual(result.rows, [null]);
  await tick();
  assert.deepEqual(result.rows.at(-1).rows, records);
  assert.equal(result.requests.length, 1);
});

test("deleting the last payment on a page moves back to the last valid page", async () => {
  const result = runEffect({ page: 2, data: { rows: [], total: 10 } });
  await tick();
  assert.deepEqual(result.pages, [1]);
  assert.equal(result.rows.at(-1), null);
});

test("an older in-flight page cannot repopulate the cache after a payment mutation", async () => {
  const cache = new RuntimeResourceCache();
  let resolveOld;
  const oldRequest = cache.hydrate(key, () => new Promise(resolve => { resolveOld = resolve; }));
  const obsolete = runEffect({ cache });
  obsolete.cleanup();
  vm.runInNewContext(`${helper}\nmarkUrbanPaymentCachesStale();`, { resourceCache: cache });
  const updated = runEffect({ cache, records: [{ id: "remaining" }], data: { rows: [{ id: "remaining" }], total: 1 } });
  await tick();
  resolveOld({ rows: [{ id: "deleted" }], total: 1 });
  await oldRequest; await tick();
  assert.equal(cache.get(key).data.rows[0].id, "remaining");
  assert.equal(updated.rows.at(-1).rows[0].id, "remaining");
  assert.deepEqual(obsolete.rows, [null]);
});

test("successful payment deletion removes its local row before the full reload finishes", async () => {
  const cache = new RuntimeResourceCache();
  await cache.hydrate(key, async () => ({ rows: [{ id: "deleted" }], total: 1 }));
  let rows = [{ id: "deleted" }, { id: "remaining" }], finishReload;
  const reload = new Promise(resolve => { finishReload = resolve; });
  const pending = vm.runInNewContext(`${helper}\n${functions.get("deletePaymentRecord").getText(ast)}\ndeletePaymentRecord("deleted");`, {
    activeMembership: { organization_id: "org" }, crypto: { randomUUID: () => "operation" },
    supabase: { rpc: async () => ({ error: null }) }, resourceCache: cache,
    setUrbanSyncing() {}, setRemoteMessage() {}, P: update => { rows = update(rows); },
    loadUrbanStructure: () => reload,
  });
  await tick();
  assert.deepEqual(rows, [{ id: "remaining" }]);
  assert.equal(cache.get(key), undefined);
  finishReload(); await pending;
});

test("failed payment deletion leaves the existing row unchanged", async () => {
  const messages = [];
  await vm.runInNewContext(`${functions.get("deletePaymentRecord").getText(ast)}\ndeletePaymentRecord("existing");`, {
    activeMembership: { organization_id: "org" }, crypto: { randomUUID: () => "operation" },
    supabase: { rpc: async () => ({ error: { message: "No se pudo eliminar" } }) },
    setUrbanSyncing() {}, setRemoteMessage: value => messages.push(value),
    P: () => assert.fail("A failed deletion must not hide the payment"),
    loadUrbanStructure: () => assert.fail("A failed deletion must not trigger a success reload"),
  });
  assert.deepEqual(messages, ["No se pudo eliminar"]);
});
