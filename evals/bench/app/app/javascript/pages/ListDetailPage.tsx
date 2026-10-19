import { useEffect, useState } from "react";
import { get, post } from "../utils/api";
import type { List, Task } from "../types";

export default function ListDetailPage({ id, tab = "tasks" }: { id: string; tab?: "tasks" | "members" | "share" }) {
  const [list, setList] = useState<List | null>(null);
  const [tasks, setTasks] = useState<Task[]>([]);
  const [shareUrl, setShareUrl] = useState<string | null>(null);

  useEffect(() => {
    get<List>(`/lists/${id}`).then(setList);
    get<Task[]>(`/tasks?list_id=${id}`).then(setTasks);
  }, [id]);

  async function deliver() {
    const delivered = await post<List>(`/lists/${id}/deliver`);
    setList(delivered);
  }

  async function share() {
    const link = await post<{ url: string }>(`/lists/${id}/share_links`, { show_drafts: "false" });
    setShareUrl(link.url);
  }

  if (!list) return <p>Loading...</p>;

  return (
    <section>
      <h1>{list.name}</h1>
      <button onClick={deliver} disabled={list.state !== "active"}>Deliver</button>
      {tab === "tasks" && (
        <ul>{tasks.map((task) => <li key={task.id}>{task.title}</li>)}</ul>
      )}
      {tab === "members" && (
        <p>{list.member_ids.length} members</p>
      )}
      {tab === "share" && (
        <div>
          <button onClick={share}>Create share link</button>
          {shareUrl && <code>{shareUrl}</code>}
        </div>
      )}
    </section>
  );
}
