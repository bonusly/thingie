import { useEffect, useState } from "react";
import { getPaged } from "../utils/api";
import { relativeDue } from "../utils/dates";
import { DEFAULT_PER_PAGE, pageQuery, rangeLabel } from "../utils/pagination";
import type { Task } from "../types";

interface Props {
  filter?: "mine" | "overdue";
}

export default function TasksPage({ filter }: Props) {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [page, setPage] = useState(1);
  const [total, setTotal] = useState(0);

  useEffect(() => {
    const query = new URLSearchParams(pageQuery({ page, perPage: DEFAULT_PER_PAGE }));
    if (filter === "overdue") query.set("due_before", new Date().toISOString().slice(0, 10));
    if (filter === "mine") query.set("assignee_id", "me");
    getPaged<Task>(`/tasks?${query}`).then((result) => {
      setTasks(result.items);
      setTotal(result.total);
    });
  }, [filter, page]);

  return (
    <section>
      <header>
        <h1>Tasks</h1>
        <span>{rangeLabel({ page, perPage: DEFAULT_PER_PAGE, total })}</span>
      </header>
      <ul>
        {tasks.map((task) => (
          <li key={task.id} className={task.overdue ? "task overdue" : "task"}>
            <a href={`/tasks/${task.id}`}>{task.title}</a>
            <small>{relativeDue(task.due_on)}</small>
            {task.points > 0 && <span className="points">{task.points} pts</span>}
          </li>
        ))}
      </ul>
      <footer>
        <button disabled={page === 1} onClick={() => setPage(page - 1)}>Previous</button>
        <button disabled={page * DEFAULT_PER_PAGE >= total} onClick={() => setPage(page + 1)}>Next</button>
      </footer>
    </section>
  );
}
