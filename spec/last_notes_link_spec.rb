# frozen_string_literal: true

require_relative 'spec_helper'

# F3: the issue list tells the page which Last notes cells get an "Add a note"
# link. Decided on the server, from the query and the user's permissions.
RSpec.describe 'the Add a note link in Last notes' do
  let(:project) { Project.find(1) }
  let(:session) { cma_session }
  let(:user) { cma_user }
  let(:columns) { %w[subject last_notes] }

  def login_with(permissions)
    cma_member(user, project, permissions)
    cma_login(session, user.login, 'cmaPassword1!')
  end

  def index(columns: self.columns, extra: {})
    session.get '/projects/ecookbook/issues', :params => {:set_filter => 1, :f => ['status_id'], :op => {'status_id' => '*'},
                                                          :c => columns, :sort => 'id', :per_page => 100}.merge(extra)
    expect(session.response.status).to eq(200)
    session.response.body
  end

  def config(body)
    body[%r{<div id="cma-last-notes".*?</div>}m]
  end

  def ids(body)
    JSON.parse(CGI.unescapeHTML(config(body)[/data-ids="([^"]*)"/, 1]))
  end

  it 'lists the issues of the page that allow notes' do
    login_with([:view_issues, :add_issue_notes])
    body = index

    expect(config(body)).not_to be_nil
    # The project list includes subproject issues, where the Non member role of
    # the fixtures may add notes too: core's own answer per issue is the measure.
    listed = body.scan(/id="issue-(\d+)"/).flatten.map(&:to_i)
    expect(ids(body)).to match_array(Issue.where(:id => listed).select { |issue| issue.notes_addable?(user) }.map(&:id))
    expect(ids(body)).to include(*project.issues.pluck(:id) & listed)
  end

  it 'leaves out issues where the user may not add notes' do
    login_with([:view_issues, :add_issue_notes])
    role = Member.find_by(:user_id => user.id, :project_id => project.id).roles.first
    role.set_permission_trackers(:add_issue_notes, [1])
    role.save!

    listed = ids(index)
    expect(listed).not_to be_empty
    expect(Issue.where(:id => listed).pluck(:tracker_id).uniq).to eq([1])
  end

  it 'gives the link the columns of the list and core markup' do
    login_with([:view_issues, :add_issue_notes])
    block = config(index)

    expect(block).to include('hidden')
    expect(block).to include('c%5B%5D=last_notes')
    link = block[%r{<a [^>]*>.*?</a>}m]
    expect(link).to include('data-remote="true"')
    expect(link).to include('class="icon icon-comment cma-last-notes-link cma-open"')
    expect(link).to include(I18n.t(:label_add_note))
  end

  it 'is absent when the list does not show Last notes' do
    login_with([:view_issues, :add_issue_notes])
    expect(config(index(columns: %w[subject]))).to be_nil
  end

  it 'is absent without add_issue_notes' do
    Role.non_member.remove_permission!(:add_issue_notes)
    login_with([:view_issues])
    expect(config(index)).to be_nil
  end

  it 'is absent when the link or Add a note is switched off' do
    login_with([:view_issues, :add_issue_notes])
    cma_settings('enable_last_notes_link' => '0')
    expect(config(index)).to be_nil

    cma_settings('enable_last_notes_link' => '1', 'enable_notes' => '0')
    expect(config(index)).to be_nil
  end

  it 'is absent on an empty list' do
    login_with([:view_issues, :add_issue_notes])
    expect(config(index(extra: {:f => ['subject'], :op => {'subject' => '~'}, :v => {'subject' => ['no such subject']}}))).to be_nil
  end

  it 'adds no query per listed issue' do
    login_with([:view_issues, :add_issue_notes])
    20.times { cma_issue(project: project) }
    count = lambda do |per_page|
      2.times.map do
        cma_queries { index(extra: {:per_page => per_page}) }.size
      end.last
    end

    with_link = [count.call(5), count.call(25)]
    cma_settings('enable_last_notes_link' => '0')
    without_link = [count.call(5), count.call(25)]

    expect(with_link[1] - without_link[1]).to eq(with_link[0] - without_link[0])
  end
end
