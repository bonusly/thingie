import { useEffect, useState } from "react";
import { get, post } from "../utils/api";
import { formatDateTime } from "../utils/dates";
import type { Notification } from "../types";

export default function NotificationsPage() {
  const [notifications, setNotifications] = useState<Notification[]>([]);

  useEffect(() => {
    get<Notification[]>("/notifications").then(setNotifications);
  }, []);

  async function markRead(notification: Notification) {
    const updated = await post<Notification>(`/notifications/${notification.id}/mark_read`);
    setNotifications(notifications.map((item) => (item.id === updated.id ? updated : item)));
  }

  async function markAll() {
    await post("/notifications/mark_all_read");
    setNotifications(notifications.map((item) => ({ ...item, read: true })));
  }

  return (
    <section>
      <header>
        <h1>Notifications</h1>
        <button onClick={markAll}>Mark all read</button>
      </header>
      <ul>
        {notifications.map((notification) => (
          <li key={notification.id} className={notification.read ? "read" : "unread"}>
            <span>{notification.title}</span>
            <time>{formatDateTime(notification.created_at)}</time>
            {!notification.read && <button onClick={() => markRead(notification)}>Mark read</button>}
          </li>
        ))}
      </ul>
    </section>
  );
}
