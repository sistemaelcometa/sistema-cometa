function isCompleteDate(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return false;
  const [, yearText, monthText, dayText] = match;
  const year = Number(yearText), month = Number(monthText), day = Number(dayText);
  if (year < 1000) return false;
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year
    && date.getUTCMonth() === month - 1
    && date.getUTCDate() === day;
}

export function validateAvailabilityDates(from: string, to: string) {
  if (!isCompleteDate(from) || !isCompleteDate(to)) {
    return { valid: false, message: "Completá las fechas de ingreso y egreso." };
  }
  if (to <= from) {
    return { valid: false, message: "El egreso debe ser posterior al ingreso." };
  }
  return { valid: true, message: "" };
}
