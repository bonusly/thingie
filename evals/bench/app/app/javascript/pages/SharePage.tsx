import { useEffect, useState } from "react";

interface SharedDraft {
  id: string;
  title: string;
  author_name: string | null;
  points: number;
}

interface SharedList {
  name: string;
  description: string | null;
  tasks: { id: string; title: string; state: string }[];
  drafts: SharedDraft[];
  expires_at: string;
}

export default function SharePage({ token }: { token: string }) {
  const [list, setList] = useState<SharedList | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch(`/s/${token}`)
      .then((response) => (response.ok ? response.json() : Promise.reject(new Error("This link has expired"))))
      .then(setList)
      .catch((failure: Error) => setError(failure.message));
  }, [token]);

  if (error) return <p className="error">{error}</p>;
  if (!list) return <p>Loading...</p>;

  return (
    <article>
      <h1>{list.name}</h1>
      {list.description && <p>{list.description}</p>}
      <ul>
        {list.tasks.map((task) => <li key={task.id} className={task.state}>{task.title}</li>)}
      </ul>
      {list.drafts.length > 0 && (
        <aside>
          <h2>Coming up</h2>
          <ul>
            {list.drafts.map((draft) => (
              <li key={draft.id}>{draft.title} {draft.author_name ? `by ${draft.author_name}` : ""}</li>
            ))}
          </ul>
        </aside>
      )}
    </article>
  );
}
