export type Role = "member" | "admin" | "staff";

export type Permission =
  | "tasks:read"
  | "tasks:write"
  | "lists:read"
  | "lists:share"
  | "drafts:read"
  | "points:read"
  | "connectors:read"
  | "members:manage"
  | "webhooks:manage"
  | "admin:staff";

const MEMBER: Permission[] = [
  "tasks:read",
  "tasks:write",
  "lists:read",
  "lists:share",
  "drafts:read",
  "points:read",
  "connectors:read",
];

const ADMIN: Permission[] = [...MEMBER, "members:manage", "webhooks:manage"];

const STAFF: Permission[] = [...ADMIN, "admin:staff"];

export const ROLE_PERMISSIONS: Record<Role, Permission[]> = {
  member: MEMBER,
  admin: ADMIN,
  staff: STAFF,
};

export function hasPermission(role: Role, permission: Permission | undefined): boolean {
  if (!permission) return true;
  return ROLE_PERMISSIONS[role].includes(permission);
}

export function roleFor(profile: { role: "member" | "admin"; staff: boolean }): Role {
  if (profile.staff) return "staff";
  return profile.role;
}
