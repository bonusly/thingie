# Escrow points on draft tasks

Marking a draft ready now holds its points in escrow against the author's weekly budget, and sending it
moves that amount into the ledger instead of running the task through the normal award path.

**What changed**

- `DraftTask` validates `points` against the author's weekly budget (`points_within_budget`), gains a
  `reserving` scope and `release_reservation!`, which moves a ready draft back to drafting.
- `GivingBalance` reports the escrow as `reserved` and exposes `escrowed?`.
- `MarkReady` checks the balance and takes the hold; `Release` frees it. Lock contention comes back as a
  normal command failure instead of an exception.
- `SendDraft` creates the task with `escrowed: true` so `Tasks::Commands::Create` neither re-checks the
  balance (the hold is already subtracted) nor awards again; `Points::Commands::SettleReservation` then
  writes the ledger entry tied to the draft (`draft_task_id`) and the task. `send_now` accepts an optional
  `points` override so a sender can adjust the reward at send time.
- `Update` writes only the changed fields so an edit cannot clobber a concurrent state change.
- `GET /api/v1/draft_tasks/reservations` lists the drafts holding the caller's points, newest first,
  capped by `limit`. Draft JSON carries `author_name`.
- Share pages show drafts sent in the last 7 days with the task they became, next to the ready ones.
- `Points::Jobs::ReleaseStaleReservationsJob` runs nightly and releases ready drafts whose author no
  longer has an active membership.

**Tradeoff**

Drafts of deactivated users are released by the nightly job rather than on deactivation. Memberships are
removed in several places (admin UI, SCIM, company purge) and I did not want to thread a release through
each for this PR; a stale hold lingers for at most a day and only affects the departed user's own budget.

**Testing**

- Specs for the model, every command, the new query, the job, the blueprint and the public view; request
  specs for the reservations endpoint, send_now and the share page.
- Manually: draft with 20 points, mark ready, `/api/v1/points` shows 20 reserved; send, one ledger entry
  for 20 with the draft id, balance moves from reserved to spent. Removed a membership, ran the job,
  draft went back to drafting.

## Files

48 files at the final push (38 modified, 10 added); a first push with 46 files, 8 of them different from the final push.
The diff of each push against the fixture app: `git -C evals/bench/tmp/draft-tasks-model diff pr-base pr-final-push` after a run, or build it with `bundle exec ruby -e 'require "./evals/bench/lib/bench"; Bench::Case.load("draft-tasks-model").build'`.

- modified `app/controllers/api/v1/draft_tasks_controller.rb`
- modified `app/javascript/pages/DraftTasksPage.tsx`
- modified `app/javascript/types.ts`
- modified `app/lib/draft_tasks/blueprints/draft_task_blueprint.rb`
- modified `app/lib/draft_tasks/commands/create.rb`
- modified `app/lib/draft_tasks/commands/mark_ready.rb`
- modified `app/lib/draft_tasks/commands/release.rb`
- modified `app/lib/draft_tasks/commands/send_draft.rb`
- modified `app/lib/draft_tasks/commands/update.rb`
- added `app/lib/draft_tasks/queries/list_reservations.rb`
- modified `app/lib/lists/services/draft_public_view.rb`
- modified `app/lib/points/blueprints/ledger_entry_blueprint.rb`
- added `app/lib/points/commands/release_stale_reservations.rb`
- added `app/lib/points/commands/settle_reservation.rb`
- added `app/lib/points/jobs/release_stale_reservations_job.rb`
- modified `app/lib/points/queries/giving_balance.rb`
- added `app/lib/points/services/with_locked_giver.rb`
- modified `app/lib/sharing/queries/public_list.rb`
- modified `app/lib/tasks/commands/create.rb`
- modified `app/models/draft_task.rb`
- modified `app/models/points_ledger_entry.rb`
- modified `config/locales/en.yml`
- modified `config/locales/en/lists.yml`
- modified `config/locales/en/tasks.yml`
- modified `config/routes.rb`
- modified `config/sidekiq.yml`
- modified `spec/factories/draft_tasks.rb`
- modified `spec/factories/points_ledger_entries.rb`
- modified `spec/lib/draft_tasks/blueprints/draft_task_blueprint_spec.rb`
- modified `spec/lib/draft_tasks/commands/create_spec.rb`
- modified `spec/lib/draft_tasks/commands/mark_ready_spec.rb`
- modified `spec/lib/draft_tasks/commands/release_spec.rb`
- modified `spec/lib/draft_tasks/commands/send_draft_spec.rb`
- modified `spec/lib/draft_tasks/commands/update_spec.rb`
- added `spec/lib/draft_tasks/queries/list_reservations_spec.rb`
- modified `spec/lib/lists/services/draft_public_view_spec.rb`
- added `spec/lib/points/commands/release_stale_reservations_spec.rb`
- added `spec/lib/points/commands/settle_reservation_spec.rb`
- added `spec/lib/points/jobs/release_stale_reservations_job_spec.rb`
- modified `spec/lib/points/queries/giving_balance_spec.rb`
- added `spec/lib/points/services/with_locked_giver_spec.rb`
- modified `spec/lib/sharing/queries/public_list_spec.rb`
- modified `spec/lib/tasks/commands/create_spec.rb`
- modified `spec/models/draft_task_spec.rb`
- modified `spec/models/points_ledger_entry_spec.rb`
- modified `spec/requests/api/v1/draft_tasks_spec.rb`
- modified `spec/requests/api/v1/points_spec.rb`
- modified `spec/requests/public/share_pages_spec.rb`


## Planted defects (real)

| Defect | File | Push | | Mechanism |
|---|---|---|---|---|
| Concurrent mark_ready calls can over-reserve the budget | `app/lib/draft_tasks/commands/mark_ready.rb` | first |  | Early MarkReady#reserve reads GivingBalance (a plain DraftTask.ready.where(author_id:) sum) and calls mark_ready! under only the per-draft lock, so two mark_ready requests for two drafts of one author both see the pre-hold balance and both pass, holding more than the weekly budget. Head wraps the check and transition in Points::Services::WithLockedGiver. |
| release_reservation! can undo a concurrent send | `app/models/draft_task.rb` | first |  | Early DraftTask#release_reservation! checks ready? in memory then does an unfiltered set(state: "drafting", ready_at: nil). ReleaseStaleReservations iterates drafts outside the draft lock, so an instance loaded as ready that SendScheduledDraftsJob sends meanwhile is written back to drafting after its task and ledger entry exist, and can be sent again. Head claims it with where(_id:, state: "ready").find_one_and_update and raises WrongState on nil. |
| Update can overwrite a draft that was sent in the meantime | `app/lib/draft_tasks/commands/update.rb` | both |  | Update#call checks editable? on the in-memory draft, then runs DraftTask.where(_id: draft.id).find_one_and_update({"$set" => changes}) with no state filter and ignores the returned document, so an edit landing after a concurrent mark_ready + send overwrites title/points on a sent draft. It should filter on state: "drafting" and fail when nil comes back. |
| Private sent drafts leak the author's name on the share page | `app/lib/lists/services/draft_public_view.rb` | both |  | DraftPublicView#call branches on draft.sent?; only pending_view consults draft.private?. sent_view always renders draft.author.display_name, and PublicList now includes drafts sent in the last 7 days, so GET /s/:token shows the author of a private draft as soon as it has a sent_task_id. |
| Ledger entry on send uses the request's points, not the reservation | `app/lib/draft_tasks/commands/send_draft.rb` | final |  | SendDraft#settle_amount returns points.to_i when send_now carries a points param and passes it to SettleReservation, while the task is built from locked.task_attributes (the held amount) and the balance was checked against locked.points. points: 1 (or 500) moves a different amount through the ledger than was held or put on the task, with no balance check. |

`push` says where the defect exists: `first` means the author fixed it before the final push (scored only at the first push), `both` means it is still there at the final push, `final` means the final push introduced it.

## Nit bait

| Finding | File | Push | Kind | Why a reviewer would merge anyway |
|---|---|---|---|---|
| limit param parsing turns an array into 1 | `app/controllers/api/v1/draft_tasks_controller.rb` | both | latent edge case | reservation_limit does (params[:limit].presence \|\| DEFAULT).to_s.to_i.clamp(1, 100); a limit[] array stringifies to '["5"]', to_i gives 0, clamp gives 1. No client sends an array-shaped limit. |
| author_name field queries the author per draft | `app/lib/draft_tasks/blueprints/draft_task_blueprint.rb` | both | performance | field :author_name calls draft.author.display_name, one User read per draft on index (paginated to 25) and reservations (capped at 100); the author is the caller on both, so cheap primary-key reads. |
| Duplicate reservation case in the balance spec | `spec/lib/points/queries/giving_balance_spec.rb` | both | test gap | "holds escrow for the author's ready drafts and nobody else's" sets up and asserts exactly what "subtracts reservations held by ready drafts only" already covers, under a different name. |
| Lock contention reported as 422 instead of 409 | `app/lib/draft_tasks/commands/mark_ready.rb` | both | messaging | MarkReady rescues Lock::Busy (and the giver lock at head) into Result.failure(e.message), a string, so render_failure answers 422 instead of the 409 HandlesErrors maps the exception to. The request is correctly refused and nothing is written; only the status is misleading. |
| Deactivated users' drafts are released nightly, not on deactivation | `app/lib/points/jobs/release_stale_reservations_job.rb` | both | documented tradeoff | A removed member's ready drafts keep their hold until the 00:15 job runs. The PR body states this on purpose and the hold only affects the departed user's own budget. |
| assignees plural keys never match English rules | `config/locales/en/tasks.yml` | both | latent edge case | the assignees entry uses plural keys English never selects, so one form is dead; the rendered copy is correct for every count a caller sends |
| Inconsistent indentation in routes.rb | `config/routes.rb` | both | style | a nested resources block is indented one level off; routes resolve the same |

## Wrong bait

| Finding | File | Push | | Why it is not a bug |
|---|---|---|---|---|
| rescue StandardError around the ledger write looks like it swallows failures | `app/lib/points/commands/settle_reservation.rb` | both |  | SettleReservation#write_entry rescues StandardError, logs, then bare `raise` re-raises, so a failed ledger write still propagates out of SendDraft and the draft stays ready. Nothing is swallowed. |
| mark_sent! looks like it runs outside the draft lock | `app/lib/draft_tasks/commands/send_draft.rb` | both |  | finalize(locked, task) is a private method, but it is only called from inside the WithLockedDraft.call block with the instance the block yielded, so mark_sent! runs while the per-draft lock is held. |
| Create does not check the author's balance | `app/lib/draft_tasks/commands/create.rb` | both |  | Creating a draft holds nothing, so no remaining-balance check belongs there; the cap is enforced by DraftTask's validate :points_within_budget (points <= membership.points_budget), which Create hits via draft.save, and the remaining-balance check happens in MarkReady when the hold is taken. |
| Non-local return inside the lock blocks skips lock cleanup | `app/lib/draft_tasks/commands/mark_ready.rb` | both |  | the return statements inside the WithLockedDraft.call and WithLockedGiver.call blocks unwind past the services, but both services release their lock in an ensure (with_locked_draft.rb, with_locked_giver.rb), which runs on return; nothing is skipped |
