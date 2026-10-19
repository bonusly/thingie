import { useEffect, useState } from "react";
import { get, post } from "../utils/api";
import { formatDateTime } from "../utils/dates";
import type { DraftTask } from "../types";

export default function DraftTasksPage({ listId }: { listId?: string }) {
  const [drafts, setDrafts] = useState<DraftTask[]>([]);

  useEffect(() => {
    const query = listId ? `?list_id=${listId}` : "";
    get<DraftTask[]>(`/draft_tasks${query}`).then(setDrafts);
  }, [listId]);

  async function transition(draft: DraftTask, action: "mark_ready" | "release") {
    const updated = await post<DraftTask>(`/draft_tasks/${draft.id}/${action}`);
    setDrafts(drafts.map((item) => (item.id === updated.id ? updated : item)));
  }

  return (
    <section>
      <h1>Drafts</h1>
      <table>
        <tbody>
          {drafts.map((draft) => (
            <tr key={draft.id} className={`draft ${draft.state}`}>
              <td>{draft.title}</td>
              <td>{draft.points} pts</td>
              <td>{draft.scheduled_for ? formatDateTime(draft.scheduled_for) : "unscheduled"}</td>
              <td>
                {draft.state === "drafting" && <button onClick={() => transition(draft, "mark_ready")}>Mark ready</button>}
                {draft.state === "ready" && <button onClick={() => transition(draft, "release")}>Back to drafting</button>}
                {draft.state === "sent" && <span>Sent</span>}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
