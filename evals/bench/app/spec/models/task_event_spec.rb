require "rails_helper"

RSpec.describe TaskEvent do
  it "requires a known kind" do
    expect(build(:task_event, kind: "sneezed")).not_to be_valid
  end

  describe ".track!" do
    it "records the event against the task's company" do
      task = create(:task)
      actor = create(:user)
      event = described_class.track!(task: task, actor: actor, kind: "completed", data: { by: "spec" })

      expect(event.company).to eq(task.company)
      expect(event.actor).to eq(actor)
      expect(event.data).to eq("by" => "spec")
    end
  end

  describe ".chronological" do
    it "orders oldest first" do
      task = create(:task)
      later = create(:task_event, task: task, company: task.company, created_at: 1.minute.ago)
      earlier = create(:task_event, task: task, company: task.company, created_at: 1.hour.ago)
      expect(task.events.chronological.to_a).to eq([earlier, later])
    end
  end
end
