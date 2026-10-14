export function roundPaymentAmount(amount: number): number {
  return Math.round((Number(amount || 0) + Number.EPSILON) * 100) / 100;
}

export function calculateUrbanPaymentAmounts({
  rent,
  expenses,
  paid,
  lateDays,
  expenseFactor,
  surchargeWaived,
}: {
  rent: number;
  expenses: number;
  paid: number;
  lateDays: number;
  expenseFactor: number;
  surchargeWaived: boolean;
}) {
  const rentCents = Math.round(rent * 100);
  const expenseCents = Math.round(expenses * 100);
  const rentDueCents = surchargeWaived
    ? rentCents
    : Math.round(rentCents * (1 + lateDays * 0.01));
  const expenseDueCents = surchargeWaived
    ? expenseCents
    : Math.round(expenseCents * expenseFactor);
  const totalCents = rentDueCents + expenseDueCents;

  return {
    rentSurcharge: Math.max(0, rentDueCents - rentCents) / 100,
    expenseSurcharge: Math.max(0, expenseDueCents - expenseCents) / 100,
    total: totalCents / 100,
    pending: Math.max(0, totalCents - Math.round(paid * 100)) / 100,
  };
}

export function formatPaymentCurrency(amount: number, currency = "ARS"): string {
  const formatted = new Intl.NumberFormat("es-AR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(Number(amount || 0));
  return `${currency === "ARS" ? "$" : "USD"} ${formatted}`;
}
