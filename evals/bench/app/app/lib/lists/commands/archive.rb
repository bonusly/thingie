module Lists
  module Commands
    class Archive
      def self.call(list:, actor:)
        new(list: list, actor: actor).call
      end

      def initialize(list:, actor:)
        @list = list
        @actor = actor
      end

      def call
        return Result.failure(Lists::Archived.new(list)) unless list.may_archive?

        list.archive!
        list.share_links.active.each(&:revoke!)
        list.draft_tasks.ready.each { |draft| DraftTasks::Commands::Release.call(draft: draft, actor: actor) }
        AuditLog.record!(company: list.company, actor: actor, action: "list.archived", target: list)
        Result.success(list)
      end

      private

      attr_reader :list, :actor
    end
  end
end
