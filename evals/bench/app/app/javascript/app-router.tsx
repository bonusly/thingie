import { lazy } from "react";
import type { LazyExoticComponent, ComponentType } from "react";
import { PERMISSIONS } from "./permissions";
import type { Permission } from "./permissions";
import { FLAGS } from "@app/flags";
import type { Flag } from "@app/flags";
import { requireAdmin } from "./components/RequireAdmin";

export interface RouteDefinition {
  path?: string;
  name?: string;
  component?: LazyExoticComponent<ComponentType<unknown>>;
  permission?: Permission;
  flag?: Flag;
  children?: RouteDefinition[];
}

const connectorRoutes: RouteDefinition[] = [
  { path: "/connectors", name: "connectors.index", component: lazy(() => import("./pages/ConnectorsPage")), permission: PERMISSIONS.CONNECTORS_READ },
  { path: "/connectors/:id", name: "connectors.show", component: lazy(() => import("./pages/ConnectorsPage")), permission: PERMISSIONS.CONNECTORS_READ },
  { path: "/connectors/:id/items", name: "connectors.items", component: lazy(() => import("./pages/ConnectorsPage")), permission: PERMISSIONS.CONNECTORS_READ },
];

export const routes: RouteDefinition[] = [
  { path: "/", name: "home", component: lazy(() => import("./pages/TasksPage")) },
  { path: "/tasks", name: "tasks.index", component: lazy(() => import("./pages/TasksPage")), permission: PERMISSIONS.TASKS_READ },
  { path: "/tasks/mine", name: "tasks.mine", component: lazy(() => import("./pages/TasksPage")), permission: PERMISSIONS.TASKS_READ },
  { path: "/tasks/overdue", name: "tasks.overdue", component: lazy(() => import("./pages/TasksPage")), permission: PERMISSIONS.TASKS_READ },
  { path: "/tasks/:id", name: "tasks.show", component: lazy(() => import("./pages/TaskDetailPage")), permission: PERMISSIONS.TASKS_READ },
  { path: "/tasks/:id/edit", name: "tasks.edit", component: lazy(() => import("./pages/TaskDetailPage")), permission: PERMISSIONS.TASKS_WRITE },
  { path: "/lists", name: "lists.index", component: lazy(() => import("./pages/ListsPage")), permission: PERMISSIONS.LISTS_READ },
  { path: "/lists/archived", name: "lists.archived", component: lazy(() => import("./pages/ListsPage")), permission: PERMISSIONS.LISTS_READ },
  { path: "/lists/:id", name: "lists.show", component: lazy(() => import("./pages/ListDetailPage")), permission: PERMISSIONS.LISTS_READ },
  { path: "/lists/:id/members", name: "lists.members", component: lazy(() => import("./pages/ListDetailPage")), permission: PERMISSIONS.LISTS_READ },
  { path: "/lists/:id/drafts", name: "lists.drafts", component: lazy(() => import("./pages/DraftTasksPage")), permission: PERMISSIONS.DRAFTS_READ },
  { path: "/lists/:id/share", name: "lists.share", component: lazy(() => import("./pages/ListDetailPage")), permission: PERMISSIONS.LISTS_SHARE },
  { path: "/drafts", name: "drafts.index", component: lazy(() => import("./pages/DraftTasksPage")), permission: PERMISSIONS.DRAFTS_READ },
  { path: "/drafts/:id", name: "drafts.show", component: lazy(() => import("./pages/DraftTasksPage")), permission: PERMISSIONS.DRAFTS_READ },
  { path: "/points", name: "points.show", component: lazy(() => import("./pages/PointsPage")), permission: PERMISSIONS.POINTS_READ },
  { path: "/points/ledger", name: "points.ledger", component: lazy(() => import("./pages/PointsPage")), permission: PERMISSIONS.POINTS_READ, flag: FLAGS.POINTS_LEDGER },
  { path: "/notifications", name: "notifications.index", component: lazy(() => import("./pages/NotificationsPage")) },
  { flag: FLAGS.CONNECTORS, children: connectorRoutes },
  {
    path: "/admin",
    name: "admin.layout",
    component: lazy(() => import("./pages/AdminLayout")),
    children: [
      {
        path: "/admin",
        name: "admin.index",
        component: lazy(() => import("./pages/AdminRoutesPage").then((m) => ({ default: m.AdminRoutesPage }))),
        permission: PERMISSIONS.ADMIN_STAFF,
      },
      { path: "/admin/companies", name: "admin.companies", component: requireAdmin(lazy(() => import("./pages/AdminCompaniesPage"))) },
      { path: "/admin/companies/:id", name: "admin.company", component: requireAdmin(lazy(() => import("./pages/AdminCompaniesPage"))) },
    ],
  },
  { path: "/s/:token", name: "share.show", component: lazy(() => import("./pages/SharePage")) },
];

export function flatten(definitions: RouteDefinition[]): RouteDefinition[] {
  return definitions.flatMap((route) => [route, ...flatten(route.children ?? [])]);
}

export function findRoute(path: string): RouteDefinition | undefined {
  return flatten(routes).find((route) => route.path !== undefined && route.component !== undefined && matchPath(route.path, path));
}

export function matchPath(pattern: string, path: string): boolean {
  const patternParts = pattern.split("/").filter(Boolean);
  const pathParts = path.split("/").filter(Boolean);
  if (patternParts.length !== pathParts.length) return false;
  return patternParts.every((part, index) => part.startsWith(":") || part === pathParts[index]);
}
