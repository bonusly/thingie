module Lists
  module Services
    class ReleaseDrafts
      SWEPT = { list_id: nil, attached_at: nil, state: "drafting", ready_at: nil }.freeze

      def self.for_card(list_id)
        list = List.find(list_id)
        DraftTask.where(list_id: list.id).not_sent.update_all(SWEPT)
      rescue Mongoid::Errors::DocumentNotFound
        Rails.logger.info("list #{list_id} is already gone, nothing to release")
        0
      end
    end
  end
end
