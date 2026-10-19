import { useEffect, useState } from "react";
import { get, post } from "../utils/api";
import type { List } from "../types";

export default function ListsPage({ archived = false }: { archived?: boolean }) {
  const [lists, setLists] = useState<List[]>([]);
  const [name, setName] = useState("");

  useEffect(() => {
    get<List[]>(`/lists?include_archived=${archived}`).then((result) =>
      setLists(result.filter((list) => (archived ? list.state === "archived" : list.state === "active")))
    );
  }, [archived]);

  async function create() {
    if (!name.trim()) return;
    const created = await post<List>("/lists", { list: { name } });
    setLists([...lists, created]);
    setName("");
  }

  return (
    <section>
      <h1>{archived ? "Archived lists" : "Lists"}</h1>
      <ul>
        {lists.map((list) => (
          <li key={list.id}>
            <a href={`/lists/${list.id}`}>{list.name}</a>
            <small>{list.open_task_count ?? 0} open</small>
            {(list.ready_draft_count ?? 0) > 0 && <small>{list.ready_draft_count} ready drafts</small>}
          </li>
        ))}
      </ul>
      {!archived && (
        <form onSubmit={(event) => { event.preventDefault(); create(); }}>
          <input value={name} onChange={(event) => setName(event.target.value)} placeholder="New list" />
          <button type="submit">Create</button>
        </form>
      )}
    </section>
  );
}
