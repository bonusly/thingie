const DAY_MS = 24 * 60 * 60 * 1000;

export function parseDate(value: string | null): Date | null {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

export function daysUntil(value: string | null, today: Date = new Date()): number | null {
  const date = parseDate(value);
  if (!date) return null;
  const start = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  return Math.round((date.getTime() - start.getTime()) / DAY_MS);
}

export function relativeDue(value: string | null, today: Date = new Date()): string {
  const days = daysUntil(value, today);
  if (days === null) return "no due date";
  if (days < 0) return `${Math.abs(days)}d overdue`;
  if (days === 0) return "due today";
  if (days === 1) return "due tomorrow";
  return `due in ${days}d`;
}

export function formatDateTime(value: string | null, locale = "en-US"): string {
  const date = parseDate(value);
  if (!date) return "";
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(date);
}

export function weekKey(date: Date): string {
  const copy = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  const day = copy.getUTCDay() || 7;
  copy.setUTCDate(copy.getUTCDate() + 4 - day);
  const yearStart = Date.UTC(copy.getUTCFullYear(), 0, 1);
  const week = Math.ceil(((copy.getTime() - yearStart) / DAY_MS + 1) / 7);
  return `${copy.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}
