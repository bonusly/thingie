export const FLAGS = {
  POINTS_LEDGER: "points_ledger",
  CONNECTORS: "connectors",
} as const;

export type Flag = (typeof FLAGS)[keyof typeof FLAGS];

export function flagEnabled(enabled: readonly string[], flag: Flag | undefined): boolean {
  if (!flag) return true;
  return enabled.includes(flag);
}
