import { useEffect, useState } from "react";
import { get, post } from "../utils/api";
import { formatDateTime } from "../utils/dates";
import type { Task } from "../types";

interface Comment {
  id: string;
  body: string;
  author_id: string;
  created_at: string;
}

export default function TaskDetailPage({ id }: { id: string }) {
  const [task, setTask] = useState<Task | null>(null);
  const [comments, setComments] = useState<Comment[]>([]);
  const [draft, setDraft] = useState("");

  useEffect(() => {
    get<Task>(`/tasks/${id}`).then(setTask);
    get<Comment[]>(`/tasks/${id}/comments`).then(setComments);
  }, [id]);

  async function toggle() {
    if (!task) return;
    const updated = await post<Task>(`/tasks/${id}/${task.state === "done" ? "reopen" : "complete"}`);
    setTask(updated);
  }

  async function submit() {
    if (!draft.trim()) return;
    const created = await post<Comment>(`/tasks/${id}/comments`, { comment: { body: draft } });
    setComments([...comments, created]);
    setDraft("");
  }

  if (!task) return <p>Loading...</p>;

  return (
    <article>
      <h1>{task.title}</h1>
      <button onClick={toggle}>{task.state === "done" ? "Reopen" : "Complete"}</button>
      {task.description && <p>{task.description}</p>}
      <ol>
        {comments.map((comment) => (
          <li key={comment.id}>
            <p>{comment.body}</p>
            <time>{formatDateTime(comment.created_at)}</time>
          </li>
        ))}
      </ol>
      <textarea value={draft} onChange={(event) => setDraft(event.target.value)} />
      <button onClick={submit}>Comment</button>
    </article>
  );
}
