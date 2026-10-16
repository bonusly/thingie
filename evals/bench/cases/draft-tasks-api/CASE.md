# Add the draft tasks API

Finishes the drafts API so the web client can ship the Drafts page. The controller that landed with the
model was a stub with no gate, no attachment support and no way to see what a draft turned into.

What's here:

- `GET /draft_tasks` (paged, `state` and `list_id` filters), `show`, `create`, `update`, `destroy`,
  `mark_ready`, `release`, `send_now`. The three transitions now take a `draft_task` body with the
  last-minute `note` and `scheduled_for` so the client can mark ready and schedule in one call.
- A writable-key guard: `state`, `author_id` and `points_reserved_at` in a body are a 422 instead of
  being silently dropped, on every mutating action.
- `PATCH /draft_tasks/:id/attachment` swaps the draft's voice or video note for an already-uploaded
  `Attachment`. The upload must be audio or video, unclaimed, and from the draft's company. On send the
  recording moves onto the task.
- `GET /draft_tasks/:id/comments` lists the sent task's comments and links each draft-originated one
  back to its draft.
- Everything sits behind `Features.enabled?(:draft_tasks, ...)` (new `Features` service, rules in
  `config/features.yml`). Off for everyone in test; on in development; two pilot companies in
  production.
- `Update` keeps a `revision` and `last_edited_by_id` so the client can detect stale edits.
- Send and release are filtered claims on the stored state (`DraftTask#claim!`) rather than AASM
  transitions on whatever was in memory, under the existing per-draft Redis lock. List delivery now
  creates the task and the note comment before finalizing so the `draft_sent` notification can carry
  the comment id.

Tradeoff, on purpose: attachment replacement removes the old recording before the new upload is
claimed, so if the claim fails validation the draft ends up with no recording. The client validates
size and type before uploading, so this only bites on an upload that slipped past that. Validating
the new one before touching the old is in a follow-up.

Testing: request specs for every endpoint, command specs for the new and reworked commands, policy and
Features specs. Ran the drafts page against this locally with the flag on for my company and walked
draft -> ready -> send, release, and a recording swap.

## Files

50 files at the final push (31 modified, 19 added); a first push with 50 files, 12 of them different from the final push.
The diff of each push against the fixture app: `git -C evals/bench/tmp/draft-tasks-api diff pr-base pr-final-push` after a run, or build it with `bundle exec ruby -e 'require "./evals/bench/lib/bench"; Bench::Case.load("draft-tasks-api").build'`.

- added `app/controllers/api/v1/draft_tasks/attachments_controller.rb`
- added `app/controllers/api/v1/draft_tasks/comments_controller.rb`
- modified `app/controllers/api/v1/draft_tasks_controller.rb`
- added `app/controllers/concerns/draft_task_scoped.rb`
- added `app/controllers/concerns/guards_writable_keys.rb`
- modified `app/controllers/concerns/handles_errors.rb`
- added `app/controllers/concerns/requires_feature.rb`
- added `app/lib/draft_tasks/blueprints/attachment_blueprint.rb`
- added `app/lib/draft_tasks/blueprints/comment_blueprint.rb`
- modified `app/lib/draft_tasks/blueprints/draft_task_blueprint.rb`
- modified `app/lib/draft_tasks/commands/destroy.rb`
- modified `app/lib/draft_tasks/commands/mark_ready.rb`
- modified `app/lib/draft_tasks/commands/release.rb`
- added `app/lib/draft_tasks/commands/replace_attachment.rb`
- modified `app/lib/draft_tasks/commands/send_draft.rb`
- modified `app/lib/draft_tasks/commands/update.rb`
- modified `app/lib/draft_tasks/errors.rb`
- modified `app/lib/draft_tasks/jobs/send_scheduled_drafts_job.rb`
- added `app/lib/draft_tasks/queries/list_draft_comments.rb`
- modified `app/lib/draft_tasks/services/with_locked_draft.rb`
- modified `app/lib/lists/commands/convert_draft_task_comment.rb`
- modified `app/lib/tasks/commands/create.rb`
- modified `app/models/attachment.rb`
- modified `app/models/draft_task.rb`
- modified `app/models/task.rb`
- modified `app/policies/draft_task_policy.rb`
- added `app/services/features.rb`
- added `config/features.yml`
- added `config/initializers/features.rb`
- modified `config/locales/en/tasks.yml`
- modified `config/routes.rb`
- modified `spec/factories/attachments.rb`
- modified `spec/factories/draft_tasks.rb`
- added `spec/lib/draft_tasks/blueprints/comment_blueprint_spec.rb`
- modified `spec/lib/draft_tasks/commands/mark_ready_spec.rb`
- modified `spec/lib/draft_tasks/commands/release_spec.rb`
- added `spec/lib/draft_tasks/commands/replace_attachment_spec.rb`
- modified `spec/lib/draft_tasks/commands/send_draft_spec.rb`
- modified `spec/lib/draft_tasks/commands/update_spec.rb`
- added `spec/lib/draft_tasks/queries/list_draft_comments_spec.rb`
- modified `spec/lib/draft_tasks/services/with_locked_draft_spec.rb`
- modified `spec/lib/lists/commands/convert_draft_task_comment_spec.rb`
- modified `spec/models/attachment_spec.rb`
- modified `spec/models/draft_task_spec.rb`
- modified `spec/policies/draft_task_policy_spec.rb`
- added `spec/requests/api/v1/draft_tasks/attachments_spec.rb`
- added `spec/requests/api/v1/draft_tasks/comments_spec.rb`
- modified `spec/requests/api/v1/draft_tasks_spec.rb`
- added `spec/services/features_spec.rb`
- added `spec/support/feature_helpers.rb`


## Planted defects (real)

| Defect | File | Push | | Mechanism |
|---|---|---|---|---|
| Transition bodies bypass the writable-key guard | `app/controllers/api/v1/draft_tasks_controller.rb` | first |  | At the early push `guard_draft_keys!` runs only for create and update, and `final_edits` is `params.fetch(:draft_task, {}).permit!.to_h`; MarkReady/Release/SendDraft then `assign_attributes` or `update` the whole hash, so a client can set `author_id` (reserving points from another member's budget and handing them the draft), `state` or `points_reserved_at` on mark_ready, release and send_now. Head guards all six mutating actions and the commands slice to FINAL_EDITS. |
| Release overwrites a concurrent send | `app/lib/draft_tasks/commands/release.rb` | first |  | At the early push Release does not take WithLockedDraft and ends with `draft.update(state: "drafting", ready_at: nil, points_reserved_at: nil)` with no state filter; a send that lands between the `draft.sent?` check and the update is overwritten, leaving a draft in drafting with a task already created and points spent. Head uses `resume_drafting!`, a filtered claim on state "ready", under the lock. |
| Attachment lookup is not scoped to the company | `app/lib/draft_tasks/commands/replace_attachment.rb` | first |  | At the early push `find_attachment` is `Attachment.where(id: attachment_id).first`, so any unclaimed audio/video upload from any company can be attached to the draft by id and then moves onto the task on send. Head scopes it with `Attachment.for_company(draft.company)`. |
| mark_sent! runs after the lock is released | `app/lib/lists/commands/convert_draft_task_comment.rb` | both |  | ConvertDraftTaskComment calls SendDraft with `finalize: false` (task created under WithLockedDraft) and then calls `draft.mark_sent!(task)` after the block has returned the lock. A release that claims ready -> drafting in between makes the claim in `mark_sent!` raise WrongState: the task exists, points are spent, and the draft is back in drafting where it can be marked ready and sent again. |
| Retry after task creation makes a second task | `app/lib/draft_tasks/commands/send_draft.rb` | both |  | SendDraft always calls `create_task(locked)` without first checking `Task.where(draft_task_id: locked.id)`. If a job (SendScheduledDraftsJob retry 3, ConvertDraftTasksJob retry 5) fails between task creation and `mark_sent!`, the retry finds the draft still ready and creates and awards a second task. |
| Policy and controller check the flag against different subjects | `app/policies/draft_task_policy.rb` | final |  | `mark_ready?` adds `Features.enabled?(:draft_tasks, user)` while RequiresFeature checks `Features.enabled?(:draft_tasks, current_company)`. Features matches a Company by slug and a User by email, so a flag rolled out with `companies:` (the production config) passes the controller and fails the policy: mark_ready is a 403 for every pilot company. Specs enable the flag with `everyone: true` so they do not see it. |

`push` says where the defect exists: `first` means the author fixed it before the final push (scored only at the first push), `both` means it is still there at the final push, `final` means the final push introduced it.

## Nit bait

| Finding | File | Push | Kind | Why a reviewer would merge anyway |
|---|---|---|---|---|
| Per-comment DraftTask.find in the comments blueprint | `app/lib/draft_tasks/blueprints/comment_blueprint.rb` | both | performance | The `draft` field does `DraftTask.find(comment.draft_task_id)` per comment. The list is capped at ListDraftComments::LIMIT (50) and in practice one comment per task comes from a draft, so this is a handful of extra reads on a cold endpoint, not something to block on. |
| Lock::Busy lives in the Send command but is raised by the lock service | `app/lib/draft_tasks/services/with_locked_draft.rb` | both | structure | WithLockedDraft raises `DraftTasks::Commands::SendDraft::Lock::Busy`, which MarkReady and Release also rescue, so the error class is owned by one command but shared by three callers and the lock service. Behaviour is correct; this is placement. |
| Old recording is removed before the new upload is validated | `app/lib/draft_tasks/commands/replace_attachment.rb` | both | documented tradeoff | `draft.attachment&.destroy` runs before `attachment.update(draft_task_id: ...)`, so a media-limit validation failure on the new upload leaves the draft with no recording. Only reachable when an over-limit media file got past the client's pre-upload check, and the PR body states it as a deliberate tradeoff with a follow-up. |
| Attachment 422 body has a different shape | `app/controllers/api/v1/draft_tasks/attachments_controller.rb` | both | messaging | Validation failures from ReplaceAttachment render `{ errors: [...] }` while InvalidAttachment and the rest of the API render `{ error: { code, message } }`. Status and behaviour are right; the client just has two shapes to parse. |
| State filter spec covers only the happy path | `spec/requests/api/v1/draft_tasks_spec.rb` | both | test gap | "lists the caller's drafts, filtered by state" asserts only `state=ready`; an unknown state value (ignored by ListDrafts) and the no-filter case are not asserted at the request level. The query spec covers both already. |

## Wrong bait

| Finding | File | Push | | Why it is not a bug |
|---|---|---|---|---|
| Mongo::Error::OperationFailure looks swallowed in the scheduled job | `app/lib/draft_tasks/jobs/send_scheduled_drafts_job.rb` | both |  | `send_one` rescues Mongo::Error::OperationFailure, logs, and then `raise`s, so Sidekiq retries the job (retry: 3). Nothing is dropped. |
| Draft lookup appears unscoped | `app/controllers/api/v1/draft_tasks_controller.rb` | both |  | `draft_tasks.find(params[:id])` reads like a bare find, but `draft_tasks` comes from DraftTaskScoped and is `current_company.draft_tasks`, a has_many relation that adds `company_id` to the criteria; another company's id raises DocumentNotFound and renders 404 (covered by the request spec). |
| Update looks like it writes twice | `app/lib/draft_tasks/commands/update.rb` | both |  | `assign_attributes` is in-memory for validation only; the single persistence is the `draft.set(...)` call that writes the changed fields, `revision` and `last_edited_by_id` in one `$set`. There is no save-then-set double write. |
