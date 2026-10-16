import type { ReactNode } from "react";

const LINKS = [
  { href: "/admin", label: "Routes" },
  { href: "/admin/companies", label: "Companies" },
];

export default function AdminLayout({ children }: { children?: ReactNode }) {
  return (
    <div className="admin">
      <nav>
        {LINKS.map((link) => (
          <a key={link.href} href={link.href}>{link.label}</a>
        ))}
      </nav>
      <main>{children}</main>
    </div>
  );
}
