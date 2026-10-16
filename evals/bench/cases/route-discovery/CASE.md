# Keep search from sending users to pages their role or flags hide

Route search returns every indexed page, so a member can land on
/admin/companies and get a 403, and anyone can find /points/ledger before
their company has the flag. This PR teaches the index about gates and
flags and filters search results by the current user.

What changed:

- `DiscoverRoutes` now parses the real shape of `app-router.tsx`: nested
  layouts with `children`, `requireAdmin(...)` wrappers, and gates written
  as `PERMISSIONS.X` / `FLAGS.Y` constants. Constants are resolved through
  the router's imports (relative paths and `tsconfig.json` path aliases)
  by a small `ConstantResolver`. The parser masks string and template
  literals first so braces inside names cannot throw off the walk.
- `RouteIndexEntry` stores `flag` and `unreadable`. When a route's
  component cannot be read, the previous entry is kept and flagged as
  unreadable instead of being pruned, so a parser gap no longer makes a
  page vanish from search; the admin routes page shows these for fixing.
- `UpsertRouteIndex` keeps the last definition when a path repeats, since
  a layout and its index child share a path and the child is the one
  people search for. It also prunes paths that are no longer in the router.
- New `SearchRoutes` query filters by the permissions of the user's role
  (plus `admin:staff` for staff) and by the company's enabled flags.
  `GET /api/v1/search/routes` uses it; the `permission` param is gone.
- Router: connector pages move under a `connectors` flag group, the admin
  pages live under an `AdminLayout` with the route index as its index
  page, and `/points/ledger` is behind `points_ledger`.
- A missing router still raises `RouterMissing`; any other read failure
  raises `FetchFailed` so the reindex job retries without touching the index.

Tradeoff, on purpose: when a layout and a child both declare a gate, the
index stores the layout's (outermost) permission. A user who holds only
the child's permission will not find that page in search, though they can
still open it by URL. Storing one permission per route keeps the query a
single `$in`; we can widen to a list if a real router ever needs it.

Testing:

- `bin/rspec spec/lib/search spec/models/route_index_entry_spec.rb`
- `bin/rails search:reindex_routes` on a seeded db, then `search:routes`
  shows gates and flags per path and `?` on unreadable entries.
- Hit `/api/v1/search/routes` as a member, an admin and a staff user;
  the admin and ledger pages only show up where expected.

## Files

24 files at the final push (13 modified, 11 added); a first push with 24 files, 3 of them different from the final push.
The diff of each push against the fixture app: `git -C evals/bench/tmp/route-discovery diff pr-base pr-final-push` after a run, or build it with `bundle exec ruby -e 'require "./evals/bench/lib/bench"; Bench::Case.load("route-discovery").build'`.

- modified `app/controllers/api/v1/search_controller.rb`
- modified `app/javascript/app-router.tsx`
- added `app/javascript/components/RequireAdmin.tsx`
- added `app/javascript/flags.ts`
- added `app/javascript/pages/AdminLayout.tsx`
- added `app/javascript/pages/AdminRoutesPage.tsx`
- modified `app/javascript/permissions.ts`
- modified `app/lib/search/blueprints/route_blueprint.rb`
- modified `app/lib/search/commands/upsert_route_index.rb`
- modified `app/lib/search/errors.rb`
- modified `app/lib/search/queries/discover_routes.rb`
- added `app/lib/search/queries/search_routes.rb`
- added `app/lib/search/services/constant_resolver.rb`
- added `app/lib/search/services/route_parser.rb`
- added `app/lib/search/services/source_mask.rb`
- modified `app/models/company.rb`
- modified `app/models/route_index_entry.rb`
- modified `lib/tasks/search.rake`
- modified `spec/factories/route_index_entries.rb`
- modified `spec/lib/search/commands/upsert_route_index_spec.rb`
- modified `spec/lib/search/queries/discover_routes_spec.rb`
- added `spec/lib/search/queries/search_routes_spec.rb`
- added `spec/lib/search/services/constant_resolver_spec.rb`
- added `tsconfig.json`


## Planted defects (real)

| Defect | File | Push | | Mechanism |
|---|---|---|---|---|
| A page whose component cannot be read lets the layout at the same path overwrite its entry | `app/lib/search/commands/upsert_route_index.rb` | both |  | UpsertRouteIndex#call partitions on readable? BEFORE one_per_route_path, so the /admin index page (component nil because its lazy().then form fails RouteParser::LAZY) is dropped, the ungated admin.layout entry is written under /admin, and `- kept_paths` suppresses the unreadable mark; search then offers /admin to every member. Dedupe first, then partition, and mark the path unreadable. |
| A transient read failure of the router empties the whole index | `app/lib/search/queries/discover_routes.rb` | first |  | early read_source rescues SystemCallError (including Errno::EACCES) to nil and call returns [], which UpsertRouteIndex#prune treats as "every route removed" and delete_all's the index; head raises Search::FetchFailed for any error other than ENOENT so the job retries instead. |
| Route groups the parser cannot read are silently dropped, so their pages are pruned as stale | `app/lib/search/services/route_parser.rb` | both |  | RouteParser#entry returns [] for an object with no `path` without descending, and entries finds no `{` after `children: connectorRoutes` (an identifier, not an array literal), so the three /connectors routes never reach the upsert and prune deletes them on the first reindex; same for a capitalised `Component` key. Unreadable shapes must be marked or fail the reindex, never pruned. |

`push` says where the defect exists: `first` means the author fixed it before the final push (scored only at the first push), `both` means it is still there at the final push, `final` means the final push introduced it.

## Nit bait

| Finding | File | Push | Kind | Why a reviewer would merge anyway |
|---|---|---|---|---|
| A comment between entries that contains a bracket makes parsing raise | `app/lib/search/services/route_parser.rb` | both | latent edge case | SourceMask does not mask // or /* */ comments, so a `{` or `[` inside a comment between two entries unbalances closing_index and raises Search::ParseError; app-router.tsx has no comments. |
| tsconfig and module files are re-read for every constant reference | `app/lib/search/services/constant_resolver.rb` | both | performance | ConstantResolver#aliases and #constant_value call File.read on every call; about twenty references per reindex on the low queue, so memoising is nice-to-have. |
| A regex literal containing a quote corrupts masking | `app/lib/search/services/source_mask.rb` | both | latent edge case | mask_string treats a `"` or `'` inside a regex literal as the start of a string and blanks source up to the next quote; app-router.tsx has no regex literals. |
| Template placeholder depth miscounts when a string inside it holds "${" | `app/lib/search/services/source_mask.rb` | both | latent edge case | mask_template counts `${` inside a nested string literal, so a template like `${"${"}` is closed too early; app-router.tsx has no template literals. |
| No spec covers a flag change on a route whose permission is unchanged | `spec/lib/search/commands/upsert_route_index_spec.rb` | both | test gap | the "updates existing entries" example only changes permission old->new; UpsertRouteIndex#upsert does write flag, so this is a missing assertion, not a bug. |
| Nested gates index the outermost permission, hiding pages from users who hold only the child's | `app/lib/search/services/route_parser.rb` | both | documented tradeoff | RouteParser#entry uses `inherited[:permission] \|\| gate(...)`, so a child gated drafts:read under a layout gated lists:read is indexed as lists:read; the PR body states this tradeoff and why. |

## Wrong bait

| Finding | File | Push | | Why it is not a bug |
|---|---|---|---|---|
| An ungated /tasks/new looks like it should take the gate from /tasks/:id at the same path | `spec/lib/search/queries/discover_routes_spec.rb` | both |  | only the custom-router fixture has an ungated static path beside a gated dynamic one; gates are per definition, DiscoverRoutes#call orders static paths first, UpsertRouteIndex keys by exact path, and the app's findRoute matches the exact entry first, so /tasks/new is genuinely ungated and nothing is lost. |
| Wildcard tsconfig aliases like @app/* are not resolved | `app/lib/search/services/constant_resolver.rb` | both |  | ConstantResolver#resolve looks aliases up by exact key, and tsconfig.json has only exact keys (@app/flags, @app/permissions), which are the only aliases the router imports; nothing is unresolved today. |
