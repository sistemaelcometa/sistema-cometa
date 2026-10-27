export function parsePdeExpenseAmount(value: string): number | null {
  let normalized = value.trim();
  if (!normalized) return null;
  if (normalized.includes(",")) {
    if (/^(?:\d+|[1-9]\d{0,2}(?:\.\d{3})+)?,\d{0,2}$/.test(normalized)) {
      normalized = normalized.replaceAll(".", "").replace(",", ".");
    } else if (/^\d{1,3}(?:,\d{3})+\.\d{1,2}$/.test(normalized)) {
      normalized = normalized.replaceAll(",", "");
    } else return null;
  } else if (/^[1-9]\d{0,2}(?:\.\d{3})+$/.test(normalized)) {
    normalized = normalized.replaceAll(".", "");
  }
  if (!/^\d*(?:\.\d{0,2})?$/.test(normalized)) return null;
  const [whole, fraction = ""] = normalized.split(".");
  const cents = Number(whole || "0") * 100 + Number(fraction.padEnd(2, "0"));
  if (!Number.isSafeInteger(cents) || cents <= 0 || cents > 99999999999999) return null;
  return cents / 100;
}

export function formatPdeExpenseInput(amount: number): string {
  return new Intl.NumberFormat("es-AR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(amount);
}

export function splitPdeExpenseAmount(amount: number): [number, number] {
  const cents = Math.round(amount * 100);
  const first = Math.round(cents / 2);
  return [first / 100, (cents - first) / 100];
}
