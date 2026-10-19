import { useEffect, useState } from "react";
import { get } from "../utils/api";
import type { Balance } from "../types";

interface LedgerEntry {
  id: string;
  amount: number;
  signed_amount: number;
  kind: string;
  week_key: string;
  note: string | null;
}

export default function PointsPage({ showLedger = false }: { showLedger?: boolean }) {
  const [balance, setBalance] = useState<Balance | null>(null);
  const [entries, setEntries] = useState<LedgerEntry[]>([]);

  useEffect(() => {
    get<Balance>("/points").then(setBalance);
    if (showLedger) get<LedgerEntry[]>("/points/ledger?weeks=4").then(setEntries);
  }, [showLedger]);

  if (!balance) return <p>Loading...</p>;

  return (
    <section>
      <h1>Points this week ({balance.week_key})</h1>
      <dl>
        <dt>Budget</dt><dd>{balance.budget}</dd>
        <dt>Spent</dt><dd>{balance.spent}</dd>
        <dt>Reserved by ready drafts</dt><dd>{balance.reserved}</dd>
        <dt>Remaining</dt><dd>{balance.remaining} ({balance.percent_remaining}%)</dd>
      </dl>
      {showLedger && (
        <ul>
          {entries.map((entry) => (
            <li key={entry.id}>
              <span>{entry.week_key}</span> <strong>{entry.signed_amount}</strong> {entry.kind} {entry.note ?? ""}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
