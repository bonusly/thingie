export type Role = "member" | "admin" | "staff";

export const PERMISSIONS = {
  TASKS_READ: "tasks:read",
  TASKS_WRITE: "tasks:write",
  LISTS_READ: "lists:read",
  LISTS_SHARE: "lists:share",
  DRAFTS_READ: "drafts:read",
  POINTS_READ: "points:read",
  CONNECTORS_READ: "connectors:read",
  MEMBERS_MANAGE: "members:manage",
  WEBHOOKS_MANAGE: "webhooks:manage",
  ADMIN_STAFF: "admin:staff",
} as const;

export type Permission = (typeof PERMISSIONS)[keyof typeof PERMISSIONS];

const MEMBER: Permission[] = [
  PERMISSIONS.TASKS_READ,
  PERMISSIONS.TASKS_WRITE,
  PERMISSIONS.LISTS_READ,
  PERMISSIONS.LISTS_SHARE,
  PERMISSIONS.DRAFTS_READ,
  PERMISSIONS.POINTS_READ,
  PERMISSIONS.CONNECTORS_READ,
];

const ADMIN: Permission[] = [...MEMBER, PERMISSIONS.MEMBERS_MANAGE, PERMISSIONS.WEBHOOKS_MANAGE];

const STAFF: Permission[] = [...ADMIN, PERMISSIONS.ADMIN_STAFF];

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
