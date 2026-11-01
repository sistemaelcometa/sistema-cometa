export function argentinaDay(date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(date);
  const part = (type: string) => parts.find(value => value.type === type)?.value;
  return `${part("year")}-${part("month")}-${part("day")}`;
}

// Poll only the clock. Reload data once per day, also after waking a sleeping tab.
export function watchArgentinaDay(onChange: () => void, clock = () => new Date()) {
  let previous = argentinaDay(clock());
  const check = () => {
    const current = argentinaDay(clock());
    if (current === previous) return;
    previous = current;
    onChange();
  };
  const interval = window.setInterval(check, 30_000);
  window.addEventListener("focus", check);
  document.addEventListener("visibilitychange", check);
  return () => {
    window.clearInterval(interval);
    window.removeEventListener("focus", check);
    document.removeEventListener("visibilitychange", check);
  };
}
