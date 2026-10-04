# frozen_string_literal: true

# Seed for the browser specs, on top of Redmine's core fixtures. Run by
# .codex/browser_test.sh against the browser database only.

project = Project.find(1)
author = User.find(1)
priority = IssuePriority.default || IssuePriority.active.first

# Enough rows for the issue list to scroll, as in a real meeting list.
40.times do |i|
  Issue.create!(:project => project, :tracker => project.trackers.first, :author => author,
                :status => IssueStatus.find(1), :priority => priority,
                :subject => format('Meeting item %02d', i + 1))
end

# One issue whose next save fails: the workflow requires a due date it does not
# have. Issue 2 is a Feature in status Assigned without a due date. Core only
# applies a rule that every role of the user has, and an administrator counts
# with all roles, so the rule is given to all of them.
Role.all.each do |role|
  WorkflowPermission.create!(:role_id => role.id, :tracker_id => 2, :old_status_id => 2,
                             :field_name => 'due_date', :rule => 'required')
end

# My page with two issue lists, one showing Last notes, one not, and an issue
# in both: a note added from one list must not add a Last notes row to the
# other. Assigned without validation, admin is no member of the project, and
# with update_all: core's nested set has already bumped the lock version.
mine = Issue.create!(:project => project, :tracker => project.trackers.first, :author => author,
                     :status => IssueStatus.find(1), :priority => priority, :subject => 'On my page twice')
Issue.where(:id => mine.id).update_all(:assigned_to_id => author.id)
pref = author.pref
pref.my_page_layout = {'top' => %w[issuesassignedtome issuesreportedbyme], 'left' => [], 'right' => []}
# Newest first: the blocks show 10 issues, and the specs before this one update
# many issues, which would push it out of core's default order.
pref.update_block_settings('issuesassignedtome', 'columns' => %w[subject status last_notes], 'sort' => [%w[id desc]])
pref.update_block_settings('issuesreportedbyme', 'columns' => %w[subject status], 'sort' => [%w[id desc]])
pref.save!

# Watchers do not matter here; mail goes nowhere in the test environment.
Setting.per_page_options = '25,50,100'
raise 'seed: My page issue not assigned' unless Issue.where(:assigned_to_id => author.id, :id => mine.id).exists?

puts "seeded: #{Issue.count} issues"
