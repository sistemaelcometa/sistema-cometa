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

test("reopening updates only the selected settlement and refreshes family caches", async () => {
  let rows = [{ id: "selected", status: "closed", is_current: true }, { id: "other", status: "closed", is_current: true }];
  const calls = [], stale = [], syncing = [], loaded = [];
  const result = await vm.runInNewContext(`${functions.get("reopenFamilySettlement")}\nreopenFamilySettlement("selected");`, {
    activeMembership: { organization_id: "org" }, crypto: { randomUUID: () => "operation" },
    supabase: { rpc: async (name, args) => { calls.push({ name, args }); return { error: null }; } },
    setUrbanSyncing: value => syncing.push(value), setFamilySettlements: update => { rows = update(rows); },
    resourceCache: { markStale: key => stale.push(key) }, markFamilySettlementCachesStale: () => stale.push("history"),
    loadFamilyData: async force => loaded.push(force), setRemoteMessage() {},
  });
  assert.equal(result, true);
  assert.equal(calls[0].name, "reopen_family_settlement");
  assert.equal(calls[0].args.target_settlement_id, "selected");
  assert.equal(calls[0].args.target_organization_id, "org");
  assert.equal(rows[0].status, "cancelled");
  assert.equal(rows[0].is_current, false);
  assert.equal(rows[1].status, "closed");
  assert.deepEqual(stale, ["familyData:", "history"]);
  assert.deepEqual(loaded, [true]);
  assert.deepEqual(syncing, [true, false]);
});

test("RPC failure does not optimistically reopen a settlement", async () => {
  const messages = [], syncing = [];
  const result = await vm.runInNewContext(`${functions.get("reopenFamilySettlement")}\nreopenFamilySettlement("selected");`, {
    activeMembership: { organization_id: "org" }, crypto: { randomUUID: () => "operation" },
    supabase: { rpc: async () => ({ error: { message: "Sin permisos" } }) },
    setUrbanSyncing: value => syncing.push(value), setRemoteMessage: value => messages.push(value),
    setFamilySettlements: () => assert.fail("Failed RPC must not change the local closure"),
  });
  assert.equal(result, "Sin permisos");
  assert.deepEqual(messages, ["Sin permisos"]);
  assert.deepEqual(syncing, [true, false]);
});

for (const result of [true, "No se pudo reabrir"]) {
  test(`confirmation ${result === true ? "closes on success" : "stays open on failure"}`, async () => {
    const closed = [], errors = [], busy = [];
    await vm.runInNewContext(`${functions.get("confirmReopenSettlement")}\nconfirmReopenSettlement();`, {
      currentSettlement: { id: "selected" }, isReopening: false, canReopen: true,
      onReopenSettlement: async id => { assert.equal(id, "selected"); return result; },
      setConfirmReopen: value => closed.push(value), setReopenError: value => errors.push(value),
      setIsReopening: value => busy.push(value),
    });
    assert.deepEqual(busy, [true, false]);
    assert.deepEqual(closed, result === true ? [false] : []);
    if (result !== true) assert.equal(errors.at(-1), result);
  });
}

test("confirmation blocks duplicate submissions and unauthorized reopening", async () => {
  for (const [isReopening, canReopen] of [[true, true], [false, false]]) {
    await vm.runInNewContext(`${functions.get("confirmReopenSettlement")}\nconfirmReopenSettlement();`, {
      currentSettlement: { id: "selected" }, isReopening, canReopen,
      onReopenSettlement: () => assert.fail("Should not reopen"),
    });
  }
});

test("reopened history has its own label instead of appearing as corrected", () => {
  const label = vm.runInNewContext(`${functions.get("familySettlementStatus")}\nfamilySettlementStatus;`);
  assert.equal(label({ statusKey: "cancelled", isCurrent: false }), "Reabierta");
  assert.equal(label({ statusKey: "closed", isCurrent: true }), "Cerrada vigente");
  assert.equal(label({ statusKey: "corrected", isCurrent: false }), "Corregida");
});
