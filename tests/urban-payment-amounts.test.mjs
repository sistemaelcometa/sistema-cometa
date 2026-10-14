import assert from "node:assert/strict";
import test from "node:test";
import { calculateUrbanPaymentAmounts, formatPaymentCurrency, roundPaymentAmount } from "../lib/urban-payment-amounts.ts";

const base = { rent: 400000, expenses: 37971.41, paid: 0, lateDays: 0, expenseFactor: 1, surchargeWaived: false };

test("a payment before the due date preserves the expense liquidation cents", () => {
  const amounts = calculateUrbanPaymentAmounts(base);
  assert.equal(amounts.total, 437971.41);
  assert.equal(amounts.pending, 437971.41);
  assert.equal(amounts.expenseSurcharge, 0);
  assert.equal(calculateUrbanPaymentAmounts({ ...base, paid: amounts.total }).pending, 0);
});

test("a whole-peso payment leaves its exact cents visible", () => {
  const amounts = calculateUrbanPaymentAmounts({ ...base, paid: 437971 });
  assert.equal(amounts.pending, 0.41);
  assert.equal(formatPaymentCurrency(amounts.pending), "$ 0,41");
  assert.equal(formatPaymentCurrency(amounts.total), "$ 437.971,41");
});

test("expense and rent surcharges round to cents, not whole pesos", () => {
  const second = calculateUrbanPaymentAmounts({ ...base, lateDays: 4, expenseFactor: 1.1 });
  assert.equal(second.rentSurcharge, 16000);
  assert.equal(second.expenseSurcharge, 3797.14);
  assert.equal(second.total, 457768.55);
  const third = calculateUrbanPaymentAmounts({ ...base, expenseFactor: 1.21 });
  assert.equal(third.expenseSurcharge, 7974);
  assert.equal(third.total, 445945.41);
});

test("waiving surcharges retains the base cents and exact partial balance", () => {
  const amounts = calculateUrbanPaymentAmounts({ ...base, lateDays: 4, expenseFactor: 1.1, surchargeWaived: true, paid: 37971.41 });
  assert.equal(amounts.rentSurcharge, 0);
  assert.equal(amounts.expenseSurcharge, 0);
  assert.equal(amounts.pending, 400000);
  assert.equal(roundPaymentAmount(437971.41 - 437971), 0.41);
});
