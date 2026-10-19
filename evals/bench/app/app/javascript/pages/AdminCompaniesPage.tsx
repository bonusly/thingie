import { useEffect, useState } from "react";
import { get, post } from "../utils/api";

interface Company {
  id: string;
  name: string;
  slug: string;
  plan: string;
  active: boolean;
  suspended_at: string | null;
}

export default function AdminCompaniesPage() {
  const [companies, setCompanies] = useState<Company[]>([]);
  const [query, setQuery] = useState("");

  useEffect(() => {
    const params = query ? `?q=${encodeURIComponent(query)}` : "";
    get<Company[]>(`/admin/companies${params}`).then(setCompanies);
  }, [query]);

  async function toggle(company: Company) {
    const action = company.active ? "suspend" : "unsuspend";
    const updated = await post<Company>(`/admin/companies/${company.id}/${action}`);
    setCompanies(companies.map((item) => (item.id === updated.id ? updated : item)));
  }

  return (
    <section>
      <h1>Companies</h1>
      <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search" />
      <table>
        <tbody>
          {companies.map((company) => (
            <tr key={company.id}>
              <td>{company.name}</td>
              <td>{company.slug}</td>
              <td>{company.plan}</td>
              <td>{company.active ? "active" : "suspended"}</td>
              <td><button onClick={() => toggle(company)}>{company.active ? "Suspend" : "Unsuspend"}</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
