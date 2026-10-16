company = Company.find_or_create_by!(slug: "acme") do |c|
  c.name = "Acme"
  c.plan = "team"
  c.weekly_points_budget = 100
  c.time_zone = "America/Denver"
end

users = %w[ada grace linus margaret].map do |handle|
  User.find_or_create_by!(email: "#{handle}@acme.test") do |u|
    u.name = handle.capitalize
    u.password = "password"
    u.time_zone = company.time_zone
  end
end

users.each_with_index do |user, index|
  Membership.find_or_create_by!(company: company, user: user) do |m|
    m.role = index.zero? ? "admin" : "member"
    m.joined_at = Time.current
  end
end

list = List.find_or_create_by!(company: company, slug: "launch") do |l|
  l.name = "Launch checklist"
  l.owner = users.first
  l.visibility = "company"
  l.member_ids = users.map(&:id)
end

%w[Write\ release\ notes Tag\ the\ build Update\ status\ page].each_with_index do |title, index|
  Task.find_or_create_by!(company: company, list: list, title: title) do |t|
    t.author = users.first
    t.assignee_ids = [users[(index + 1) % users.size].id]
    t.due_on = Date.current + (index + 1).days
    t.points = index * 5
  end
end

%w[bug chore release].each do |name|
  Label.find_or_create_by!(company: company, name: name) { |l| l.color = "#%06x" % rand(0xffffff) }
end
