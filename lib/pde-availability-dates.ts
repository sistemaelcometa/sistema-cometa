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

export function validateAvailabilityWindow(from: string, through: string) {
  if (!isCompleteDate(from) || !isCompleteDate(through)) {
    return { valid: false, message: "Completá las fechas desde y hasta." };
  }
  if (through < from) {
    return { valid: false, message: "Hasta debe ser igual o posterior a Desde." };
  }
  return { valid: true, message: "" };
}

function addCalendarDays(value: string, days: number): string {
  const date = new Date(`${value}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

type AvailabilityReservation = { unit: string; from: string; to: string; status?: string };
type AvailablePeriod = { from: string; through: string; days: number };

export function getPdeAvailability(
  units: string[], reservations: AvailabilityReservation[], from: string, through: string,
) {
  if (!validateAvailabilityWindow(from, through).valid) return [];
  const end = addCalendarDays(through, 1);
  return Array.from(new Set(units.filter(Boolean))).map(unit => {
    const active = reservations.filter(item => item.unit === unit
      && !["cancelada", "cancelled", "canceled"].includes(String(item.status || "").toLowerCase()));
    const invalidReservations = active.some(item => !validateAvailabilityDates(item.from, item.to).valid);
    const periods: AvailablePeriod[] = [];
    // Reservation departures are exclusive; the selected final day is inclusive.
    const occupied = active.filter(item => item.from < end && item.to > from)
      .map(item => ({ from: item.from < from ? from : item.from, to: item.to > end ? end : item.to }))
      .sort((left, right) => left.from.localeCompare(right.from) || left.to.localeCompare(right.to));
    let cursor = from;
    function addPeriod(until: string) {
      periods.push({ from: cursor, through: addCalendarDays(until, -1),
        days: Math.round((Date.parse(`${until}T00:00:00Z`) - Date.parse(`${cursor}T00:00:00Z`)) / 86400000) });
    }
    if (!invalidReservations) {
      for (const reservation of occupied) {
        if (reservation.from > cursor) addPeriod(reservation.from);
        if (reservation.to > cursor) cursor = reservation.to;
      }
      if (cursor < end) addPeriod(end);
    }
    return { unit, periods, invalidReservations };
  });
}
