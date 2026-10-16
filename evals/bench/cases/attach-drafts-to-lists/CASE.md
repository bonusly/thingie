# Attach draft tasks to lists and send them on delivery

Drafts used to be born on a list and stay there. This makes them free-floating: you write a draft,
then attach it to whichever list you want it delivered with. Attaching reserves the points (the draft
goes `ready`) and leaves an "Attached a draft" comment on the list so members can see what is coming.
Removing that comment detaches the draft and frees the reservation; so does `POST /draft_tasks/:id/detach`.

Delivering a list still enqueues `ConvertDraftTasksJob`, which turns each ready draft into a task and
carries the note over as a comment. The job now tells the author when a draft could not be sent
(new `draft_conversion_failed` notification) instead of only logging it. Delivery itself no longer
fails when the job cannot be enqueued; the list is delivered either way and the enqueue problem is logged.

Lists can now be deleted directly (`DELETE /lists/:id`, owner or admin) instead of only after archiving.
Deletion is a soft delete: the list is marked `deleted_at`, its attached drafts are swept back to
`drafting` with no list, their attach comments go, and share links are revoked. Finders skip deleted lists.

The share page shows attached drafts (drafting and ready) with `attached_at`, and a private draft shows
without its author. Tradeoff, on purpose: once a private draft is delivered it is a task like any other
and the tasks section of the share page now carries `author_name`, so the giver is visible from that point.
That matches what linked tasks show today; hiding it would mean a second notion of private on tasks.

`list.members` now includes the authors of attached drafts so `member_count` on the list cards reflects
everyone contributing to the list, not only the people added by hand.

## Testing

- `DraftTasks::Commands::Attach` / `Detach`: state, reservation, comment placement, moving between lists,
  busy lock, refusals.
- `Lists::Commands::Destroy` and `Lists::Services::ReleaseDrafts`: sweep order, sent drafts untouched,
  audit count, finders hiding the list.
- `Comments::Commands::Destroy`: removing an attach comment releases its draft.
- `ConvertDraftTasksJob`: deleted lists are skipped, failed drafts notify their author.
- `Deliver`: still succeeds when the enqueue raises.
- Request specs for attach/detach/mark_ready, list deletion and the public share page (private author
  hidden, converted task author shown).

## Files

50 files at the final push (39 modified, 11 added); a first push with 50 files, 8 of them different from the final push.
The diff of each push against the fixture app: `git -C evals/bench/tmp/attach-drafts-to-lists diff pr-base pr-final-push` after a run, or build it with `bundle exec ruby -e 'require "./evals/bench/lib/bench"; Bench::Case.load("attach-drafts-to-lists").build'`.

- modified `app/controllers/api/v1/draft_tasks_controller.rb`
- modified `app/controllers/api/v1/lists_controller.rb`
- modified `app/controllers/concerns/handles_errors.rb`
- modified `app/lib/comments/blueprints/comment_blueprint.rb`
- modified `app/lib/comments/commands/destroy.rb`
- added `app/lib/draft_tasks/commands/attach.rb`
- modified `app/lib/draft_tasks/commands/create.rb`
- added `app/lib/draft_tasks/commands/detach.rb`
- modified `app/lib/draft_tasks/commands/mark_ready.rb`
- modified `app/lib/draft_tasks/commands/send_draft.rb`
- modified `app/lib/draft_tasks/errors.rb`
- modified `app/lib/lists/blueprints/list_blueprint.rb`
- modified `app/lib/lists/commands/convert_draft_task_comment.rb`
- modified `app/lib/lists/commands/deliver.rb`
- added `app/lib/lists/commands/destroy.rb`
- modified `app/lib/lists/jobs/convert_draft_tasks_job.rb`
- modified `app/lib/lists/queries/find_list.rb`
- modified `app/lib/lists/queries/list_lists.rb`
- modified `app/lib/lists/services/draft_public_view.rb`
- added `app/lib/lists/services/release_drafts.rb`
- added `app/lib/sharing/blueprints/public_draft_blueprint.rb`
- modified `app/lib/sharing/blueprints/public_list_blueprint.rb`
- modified `app/lib/sharing/queries/public_list.rb`
- modified `app/lib/tasks/blueprints/task_summary_blueprint.rb`
- modified `app/models/comment.rb`
- modified `app/models/draft_task.rb`
- modified `app/models/list.rb`
- modified `app/models/notification.rb`
- modified `app/policies/draft_task_policy.rb`
- modified `app/policies/list_policy.rb`
- added `config/locales/en/draft_tasks.yml`
- modified `config/locales/en/notifications.yml`
- modified `config/routes.rb`
- modified `spec/factories/draft_tasks.rb`
- modified `spec/factories/lists.rb`
- added `spec/lib/comments/commands/destroy_spec.rb`
- added `spec/lib/draft_tasks/commands/attach_spec.rb`
- modified `spec/lib/draft_tasks/commands/create_spec.rb`
- added `spec/lib/draft_tasks/commands/detach_spec.rb`
- modified `spec/lib/draft_tasks/commands/mark_ready_spec.rb`
- modified `spec/lib/lists/commands/deliver_spec.rb`
- added `spec/lib/lists/commands/destroy_spec.rb`
- modified `spec/lib/lists/jobs/convert_draft_tasks_job_spec.rb`
- added `spec/lib/lists/services/release_drafts_spec.rb`
- modified `spec/lib/sharing/queries/public_list_spec.rb`
- modified `spec/models/list_spec.rb`
- modified `spec/requests/api/v1/draft_tasks_spec.rb`
- modified `spec/requests/api/v1/lists_spec.rb`
- modified `spec/requests/public/share_pages_spec.rb`
- modified `spec/support/shared_contexts.rb`


## Planted defects (real)

| Defect | File | Push | | Mechanism |
|---|---|---|---|---|
| Deliver swallows a failed enqueue of the conversion job and reports success | `app/lib/lists/commands/deliver.rb` | both |  | enqueue_draft_conversion rescues StandardError around ConvertDraftTasksJob.perform_async, logs a warning and Deliver returns Success; with Redis/Sidekiq down the list is stamped delivered but its ready drafts never convert, stay ready holding reserved points, and nobody is notified or retried |
| Attach writes the draft outside the per-draft lock and overwrites state | `app/lib/draft_tasks/commands/attach.rb` | first |  | early Attach does not use WithLockedDraft; it checks draft.sent? on its in-memory copy then draft.update!(list:, state: "ready", ready_at:) so a SendDraft that lands in between (send_now or SendScheduledDraftsJob) is overwritten: the sent draft is flipped back to ready on the new list and converted again on delivery; head wraps it in WithLockedDraft and uses mark_ready! |
| Public share page leaks the author of a private draft | `app/lib/sharing/blueprints/public_draft_blueprint.rb` | first |  | early PublicDraftBlueprint's author field renders view.draft.author.name (and author_id) for every draft, so a private draft has author_name nil but author.name set; the share page is unauthenticated; head renders author only from author_name |
| List deletion sweeps comments and drafts before marking the list deleted | `app/lib/lists/commands/destroy.rb` | first |  | early Destroy runs comments.delete_all and ReleaseDrafts.for_card before list.update!(deleted_at:); a ConvertDraftTasksJob already running for a delivered list passes its deleted? check and SendDraft's under-lock list.deleted? check, so a draft the sweep has not reached yet is converted into a task (points spent) on a list that is then marked deleted and invisible; head marks deleted_at first |
| Note comment failure is swallowed after the draft is already sent | `app/lib/lists/commands/convert_draft_task_comment.rb` | both |  | build_comment rescues StandardError from Comments::Commands::Create.value! (for example a note longer than Comment::MAX_BODY, which DraftTask does not validate), logs and returns nil; the task exists and the draft is sent, so the job cannot retry and the user sees a sent draft with its note missing |
| Delivery notification goes to draft authors who are not list members | `app/lib/lists/commands/deliver.rb` | final |  | List#members at head is member_ids plus attached_author_ids, and Deliver#notify_members iterates list.members, so anyone who attached a draft to a company-visible list gets a list_delivered notification for a list they are not a member of (and a draft_sent one right after); early push's members did not include draft authors |

`push` says where the defect exists: `first` means the author fixed it before the final push (scored only at the first push), `both` means it is still there at the final push, `final` means the final push introduced it.

## Nit bait

| Finding | File | Push | Kind | Why a reviewer would merge anyway |
|---|---|---|---|---|
| Duplicate failure notification when the job retries after a transient error | `app/lib/lists/jobs/convert_draft_tasks_job.rb` | both | latent edge case | notify_failure is called per failed draft with no idempotency key; if a later draft raises (Mongo blip) Sidekiq retries the job and the earlier failed draft's author gets a second draft_conversion_failed notification; needs an unhandled exception mid-loop, not reached by any normal path |
| for_card rescue hides a failed release when the list is already gone | `app/lib/lists/services/release_drafts.rb` | both | pre-existing | ReleaseDrafts.for_card rescues Mongoid::Errors::DocumentNotFound from List.find and returns 0 without sweeping; the only caller (Lists::Commands::Destroy) passes an id it just loaded so the branch is unreachable today; same shape as ConvertDraftTasksJob returning on a missing list |
| Comment list loads the draft once per comment | `app/lib/comments/blueprints/comment_blueprint.rb` | both | performance | the draft field calls comment.draft (DraftTask.where(id:).first) for each comment rendered; the comments index is paginated (25 default, 100 max) and only attach comments have draft_task_id, so it is a bounded N+1 off the hot path |
| Attach request spec stubs the command so it passes with no attach | `spec/requests/api/v1/draft_tasks_spec.rb` | both | test gap | the 'attaches the draft to the list' example stubs DraftTasks::Commands::Attach.call to return Result.success(draft) and asserts 200 and the id, so it would pass if the controller never attached anything; the command spec covers behaviour, the request spec only covers routing/authorization |
| Private draft's author appears on the public page once converted | `app/lib/tasks/blueprints/task_summary_blueprint.rb` | both | documented tradeoff | TaskSummaryBlueprint gains author_name, so a private draft that has been delivered shows its giver in the share page's tasks section; the PR body states this on purpose and explains why tasks do not get a second notion of private |

## Wrong bait

| Finding | File | Push | | Why it is not a bug |
|---|---|---|---|---|
| Comment removal releases the draft without the per-draft lock | `app/lib/comments/commands/destroy.rb` | both |  | Comments::Commands::Destroy#release_draft does not lock anything itself, but it delegates to DraftTasks::Commands::Detach, whose whole body runs inside DraftTasks::Services::WithLockedDraft (reload under the Redis lock, Busy surfaced as a failure); nothing is unlocked |
| A Redis outage makes list deletion fail while removing draft comments | `app/lib/lists/commands/destroy.rb` | both |  | Destroy removes attach comments with list.comments.from_drafts.delete_all and sweeps drafts with ReleaseDrafts.for_card (a Mongo update_all); neither goes through Comments::Commands::Destroy or Detach, so no RedisLock is taken on the deletion path and a Redis outage cannot fail it |
| Moving a draft strands its old reservation by deleting the attach comment with delete_all | `app/lib/draft_tasks/commands/attach.rb` | both |  | replace_attach_comment delete_alls the previous list's attach comment without going through Detach, but the draft is being moved, not released: it stays ready on the new list on purpose and its single reservation is still counted by GivingBalance.reserved_points; there is no second reservation to strand |
