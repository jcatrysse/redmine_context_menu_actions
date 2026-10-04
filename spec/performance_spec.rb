# frozen_string_literal: true

require_relative 'spec_helper'

# No N+1: what the plugin adds to a request must not grow with the number of
# selected issues. Measured as the difference with the plugin's part switched
# off, so core's own queries do not count.
RSpec.describe 'query counts' do
  let(:project) { Project.find(1) }
  let(:session) { cma_session }
  let(:user) { cma_user }
  let(:issues) { Array.new(10) { cma_issue(project: project) } }

  before do
    cma_member(user, project, [:view_issues, :add_issue_notes, :edit_issues, :set_notes_private])
    cma_login(session, user.login, 'cmaPassword1!')
  end

  # Measured on the second of two identical requests, so caches that the first
  # request warms up (settings, roles, custom fields) count for neither side.
  def menu_queries(ids)
    2.times.map { cma_queries { session.get '/issues/context_menu', :params => {:ids => ids}, :xhr => true }.size }.last
  end

  def with_plugin(enabled)
    cma_settings('enable_notes' => enabled ? '1' : '0', 'enable_dates' => enabled ? '1' : '0')
    yield
  end

  it 'adds a constant number of queries to the context menu, whatever the selection' do
    ids = issues.map(&:id)

    off_one = with_plugin(false) { menu_queries(ids.first(1)) }
    off_ten = with_plugin(false) { menu_queries(ids) }
    on_one = with_plugin(true) { menu_queries(ids.first(1)) }
    on_ten = with_plugin(true) { menu_queries(ids) }

    expect(on_ten - off_ten).to eq(on_one - off_one)
    expect(on_one - off_one).to be <= 2
  end

  # Each issue is then reloaded right before its own save, as core's bulk edit
  # does: a save earlier in the loop can change a later issue.
  it 'loads the issues in one query and their last notes in one, for any number of issues' do
    sql = cma_queries do
      session.post '/context_menu_actions/notes', :params => {:ids => issues.map(&:id), :notes => 'Batch', :c => %w[subject last_notes]}, :xhr => true
    end
    expect(session.response.status).to eq(200)

    issue_loads = sql.grep(/FROM ["`]?issues["`]? WHERE ["`]?issues["`]?\.["`]?id["`]? IN/i)
    expect(issue_loads.size).to eq(1), issue_loads.join("\n")
    last_note_ids = sql.grep(/MAX\(["`]?journals["`]?\.["`]?id["`]?\)/i)
    expect(last_note_ids.size).to eq(1), last_note_ids.join("\n")
  end
end
