import { lazy } from "react";
import type { LazyExoticComponent, ComponentType } from "react";
import type { Permission } from "./permissions";

export interface RouteDefinition {
  path: string;
  name: string;
  component: LazyExoticComponent<ComponentType<unknown>>;
  permission?: Permission;
}

export const routes: RouteDefinition[] = [
  { path: "/", name: "home", component: lazy(() => import("./pages/TasksPage")) },
  { path: "/tasks", name: "tasks.index", component: lazy(() => import("./pages/TasksPage")), permission: "tasks:read" },
  { path: "/tasks/mine", name: "tasks.mine", component: lazy(() => import("./pages/TasksPage")), permission: "tasks:read" },
  { path: "/tasks/overdue", name: "tasks.overdue", component: lazy(() => import("./pages/TasksPage")), permission: "tasks:read" },
  { path: "/tasks/:id", name: "tasks.show", component: lazy(() => import("./pages/TaskDetailPage")), permission: "tasks:read" },
  { path: "/tasks/:id/edit", name: "tasks.edit", component: lazy(() => import("./pages/TaskDetailPage")), permission: "tasks:write" },
  { path: "/lists", name: "lists.index", component: lazy(() => import("./pages/ListsPage")), permission: "lists:read" },
  { path: "/lists/archived", name: "lists.archived", component: lazy(() => import("./pages/ListsPage")), permission: "lists:read" },
  { path: "/lists/:id", name: "lists.show", component: lazy(() => import("./pages/ListDetailPage")), permission: "lists:read" },
  { path: "/lists/:id/members", name: "lists.members", component: lazy(() => import("./pages/ListDetailPage")), permission: "lists:read" },
  { path: "/lists/:id/drafts", name: "lists.drafts", component: lazy(() => import("./pages/DraftTasksPage")), permission: "drafts:read" },
  { path: "/lists/:id/share", name: "lists.share", component: lazy(() => import("./pages/ListDetailPage")), permission: "lists:share" },
  { path: "/drafts", name: "drafts.index", component: lazy(() => import("./pages/DraftTasksPage")), permission: "drafts:read" },
  { path: "/drafts/:id", name: "drafts.show", component: lazy(() => import("./pages/DraftTasksPage")), permission: "drafts:read" },
  { path: "/points", name: "points.show", component: lazy(() => import("./pages/PointsPage")), permission: "points:read" },
  { path: "/points/ledger", name: "points.ledger", component: lazy(() => import("./pages/PointsPage")), permission: "points:read" },
  { path: "/notifications", name: "notifications.index", component: lazy(() => import("./pages/NotificationsPage")) },
  { path: "/connectors", name: "connectors.index", component: lazy(() => import("./pages/ConnectorsPage")), permission: "connectors:read" },
  { path: "/connectors/:id", name: "connectors.show", component: lazy(() => import("./pages/ConnectorsPage")), permission: "connectors:read" },
  { path: "/connectors/:id/items", name: "connectors.items", component: lazy(() => import("./pages/ConnectorsPage")), permission: "connectors:read" },
  { path: "/admin/companies", name: "admin.companies", component: lazy(() => import("./pages/AdminCompaniesPage")), permission: "admin:staff" },
  { path: "/admin/companies/:id", name: "admin.company", component: lazy(() => import("./pages/AdminCompaniesPage")), permission: "admin:staff" },
  { path: "/admin/routes", name: "admin.routes", component: lazy(() => import("./pages/AdminCompaniesPage")), permission: "admin:staff" },
  { path: "/s/:token", name: "share.show", component: lazy(() => import("./pages/SharePage")) },
];

export function findRoute(path: string): RouteDefinition | undefined {
  return routes.find((route) => matchPath(route.path, path));
}

export function matchPath(pattern: string, path: string): boolean {
  const patternParts = pattern.split("/").filter(Boolean);
  const pathParts = path.split("/").filter(Boolean);
  if (patternParts.length !== pathParts.length) return false;
  return patternParts.every((part, index) => part.startsWith(":") || part === pathParts[index]);
}
