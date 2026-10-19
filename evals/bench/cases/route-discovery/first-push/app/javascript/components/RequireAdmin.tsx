import { useEffect, useState } from "react";
import type { ComponentType } from "react";
import { get } from "../utils/api";
import { roleFor } from "../permissions";

interface Profile {
  role: "member" | "admin";
  staff: boolean;
}

export function requireAdmin<P extends object>(Wrapped: ComponentType<P>): ComponentType<P> {
  return function RequireAdmin(props: P) {
    const [allowed, setAllowed] = useState<boolean | null>(null);

    useEffect(() => {
      get<Profile>("/me").then((profile) => setAllowed(roleFor(profile) === "staff"));
    }, []);

    if (allowed === null) return <p>Loading...</p>;
    if (!allowed) return <p className="error">You do not have access to this page.</p>;
    return <Wrapped {...props} />;
  };
}
