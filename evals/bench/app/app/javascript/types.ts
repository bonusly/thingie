export type TaskState = "open" | "done" | "archived";
export type DraftState = "drafting" | "ready" | "sent";
export type Provider = "github" | "slack" | "linear";

export interface Task {
  id: string;
  title: string;
  description: string | null;
  state: TaskState;
  due_on: string | null;
  points: number;
  list_id: string;
  author_id: string;
  assignee_ids: string[];
  label_ids: string[];
  overdue: boolean;
}

export interface DraftTask {
  id: string;
  title: string;
  note: string | null;
  state: DraftState;
  points: number;
  scheduled_for: string | null;
  visibility: "private" | "shared";
  list_id: string;
  editable: boolean;
}

export interface List {
  id: string;
  name: string;
  slug: string;
  state: "active" | "archived";
  visibility: "private" | "company" | "public";
  member_ids: string[];
  open_task_count?: number;
  ready_draft_count?: number;
}

export interface Balance {
  budget: number;
  spent: number;
  reserved: number;
  remaining: number;
  week_key: string;
  percent_remaining: number;
}

export interface Notification {
  id: string;
  kind: string;
  title: string;
  read: boolean;
  created_at: string;
}

export interface ConnectorAccount {
  id: string;
  provider: Provider;
  external_account_name: string | null;
  state: "connected" | "paused" | "disconnected";
  last_synced_at: string | null;
  item_count: number;
}
