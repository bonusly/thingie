import { useEffect, useState } from "react";
import { get, post } from "../utils/api";
import { formatDateTime } from "../utils/dates";
import type { ConnectorAccount, Provider } from "../types";

const PROVIDERS: Provider[] = ["github", "slack", "linear"];

export default function ConnectorsPage() {
  const [accounts, setAccounts] = useState<ConnectorAccount[]>([]);

  useEffect(() => {
    get<ConnectorAccount[]>("/connector_accounts").then(setAccounts);
  }, []);

  async function sync(account: ConnectorAccount) {
    await post(`/connector_accounts/${account.id}/sync`);
  }

  async function toggle(account: ConnectorAccount) {
    const action = account.state === "paused" ? "resume" : "pause";
    const updated = await post<ConnectorAccount>(`/connector_accounts/${account.id}/${action}`);
    setAccounts(accounts.map((item) => (item.id === updated.id ? updated : item)));
  }

  return (
    <section>
      <h1>Connectors</h1>
      {PROVIDERS.map((provider) => (
        <div key={provider}>
          <h2>{provider}</h2>
          <ul>
            {accounts.filter((account) => account.provider === provider).map((account) => (
              <li key={account.id}>
                <span>{account.external_account_name ?? account.id}</span>
                <small>{account.state}, {account.item_count} items, synced {formatDateTime(account.last_synced_at) || "never"}</small>
                <button onClick={() => sync(account)} disabled={account.state !== "connected"}>Sync</button>
                <button onClick={() => toggle(account)}>{account.state === "paused" ? "Resume" : "Pause"}</button>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </section>
  );
}
