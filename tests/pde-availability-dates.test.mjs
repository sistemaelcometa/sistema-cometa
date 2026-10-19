import assert from "node:assert/strict";
import test from "node:test";
import { validateAvailabilityDates } from "../lib/pde-availability-dates.ts";

test("availability waits for complete dates, including a complete year", () => {
  for (const value of ["", "2026", "2026-10", "2026-10-", "2026-1-05", "0002-10-05", "NaN-NaN-NaN"]) {
    assert.equal(validateAvailabilityDates(value, "2026-12-01").valid, false);
    assert.equal(validateAvailabilityDates("2026-01-01", value).valid, false);
  }
});

test("availability rejects impossible dates instead of silently rolling them over", () => {
  for (const value of ["2026-02-29", "2026-02-30", "2026-04-31", "2026-13-01", "2026-01-00"]) {
    assert.equal(validateAvailabilityDates("2026-01-01", value).valid, false);
  }
  assert.equal(validateAvailabilityDates("2028-02-29", "2028-03-01").valid, true);
});

test("equal and reversed date ranges require correction without changing either input", () => {
  for (const to of ["2026-10-19", "2026-10-18"]) {
    const result = validateAvailabilityDates("2026-10-19", to);
    assert.equal(result.valid, false);
    assert.equal(result.message, "El egreso debe ser posterior al ingreso.");
  }
});

test("valid stays support one night and month/year transitions", () => {
  for (const [from, to] of [["2026-10-19", "2026-10-20"], ["2026-10-31", "2026-11-01"], ["2026-12-31", "2027-01-02"]]) {
    assert.deepEqual(validateAvailabilityDates(from, to), { valid: true, message: "" });
  }
});
