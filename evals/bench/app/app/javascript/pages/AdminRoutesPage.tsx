import { useEffect, useState } from "react";
import { get, post } from "../utils/api";

interface IndexedRoute {
  id: string;
  path: string;
  name: string;
  component: string;
  permission: string | null;
  flag: string | null;
  unreadable: boolean;
  indexed_at: string;
}

interface RouteIndex {
  count: number;
  last_indexed_at: string | null;
  routes: IndexedRoute[];
}

export function AdminRoutesPage() {
  const [index, setIndex] = useState<RouteIndex | null>(null);

  useEffect(() => {
    get<RouteIndex>("/admin/route_index").then(setIndex);
  }, []);

  async function reindex() {
    await post("/admin/route_index");
    setIndex(await get<RouteIndex>("/admin/route_index"));
  }

  if (!index) return <p>Loading...</p>;

  return (
    <section>
      <header>
        <h1>Indexed routes ({index.count})</h1>
        <button onClick={reindex}>Reindex</button>
      </header>
      <table>
        <tbody>
          {index.routes.map((route) => (
            <tr key={route.id} className={route.unreadable ? "unreadable" : ""}>
              <td>{route.path}</td>
              <td>{route.name}</td>
              <td>{route.component}</td>
              <td>{route.permission ?? "-"}</td>
              <td>{route.flag ?? "-"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
