# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'security' do
  let(:project) { Project.find(1) }
  let(:session) { cma_session }
  let(:user) { cma_user }

  before do
    cma_member(user, project, [:view_issues, :add_issue_notes, :edit_issues])
    cma_login(session, user.login, 'cmaPassword1!')
  end

  def post_note(params)
    session.post '/context_menu_actions/notes', :params => params, :xhr => true
    session.response
  end

  describe 'the attribute whitelist' do
    let(:issue) { cma_issue(project: project, subject: 'Untouched') }

    it 'applies nothing but the note, whatever else the request carries' do
      post_note(:ids => [issue.id], :notes => 'Only a note',
                :issue => {:subject => 'Hacked', :status_id => 5, :assigned_to_id => 1, :start_date => '2001-01-01'},
                :subject => 'Hacked too')

      issue.reload
      expect(issue.subject).to eq('Untouched')
      expect(issue.status_id).not_to eq(5)
      expect(issue.start_date).to be_nil
      expect(issue.journals.last.notes).to eq('Only a note')
      expect(issue.journals.last.details).to be_empty
    end

    it 'refuses an attribute outside the whitelist in the service itself' do
      expect do
        RedmineContextMenuActions::IssueUpdater.new([issue], :user => user, :attributes => {'subject' => 'x'})
      end.to raise_error(ArgumentError)
    end

    it 'refuses an attribute the user may not set, instead of dropping it' do
      results = RedmineContextMenuActions::IssueUpdater.new([issue], :user => user,
                                                                     :attributes => {'notes' => 'x', 'private_notes' => '1'}).call
      expect(results.first.saved?).to be(false)
      expect(results.first.errors).to eq([I18n.t(:notice_not_authorized)])
      expect(issue.journals.count).to eq(0)
    end
  end

  describe 'parameters of an unexpected shape' do
    let(:issue) { cma_issue(project: project) }

    it 'refuses them instead of raising' do
      post_note(:ids => [issue.id], :notes => 'x', :issue => 'not-a-hash')
      expect(session.response.status).to eq(200)
      expect(issue.journals.last.notes).to eq('x')

      post_note(:ids => [issue.id], :notes => ['an', 'array'])
      expect(session.response.status).to eq(200)
      expect(cma_saved_payload(session.response.body)['saved']).to eq([])
      expect(issue.journals.count).to eq(1)

      session.patch '/context_menu_actions/dates', :params => {:ids => [issue.id], :issue => 'x', :notes => {'a' => 'b'}}, :xhr => true
      expect(session.response.status).to eq(200)
      expect(issue.journals.count).to eq(1)
    end
  end

  describe 'escaping' do
    it 'escapes a field name in an error message' do
      field = IssueCustomField.create!(:name => '<img src=x onerror=alert(1)>', :field_format => 'string',
                                       :is_for_all => true, :trackers => Tracker.all)
      issue = cma_issue(project: project)
      role = Member.find_by(:user_id => user.id, :project_id => project.id).roles.first
      WorkflowPermission.create!(:role_id => role.id, :tracker_id => issue.tracker_id, :old_status_id => issue.status_id,
                                 :field_name => field.id.to_s, :rule => 'required')

      post_note(:ids => [issue.id], :notes => 'x')
      html = cma_saved_payload(session.response.body)['errorsHtml']
      expect(html).not_to include('<img src=x')
      expect(html).to include('&lt;img src=x onerror=alert(1)&gt; ')
    end

    it 'renders a note with markup only through the wiki formatter' do
      issue = cma_issue(project: project)
      post_note(:ids => [issue.id], :notes => %(<a href="javascript:alert(1)">x</a> <img src=x onerror=alert(1)>), :c => %w[last_notes])

      html = cma_saved_payload(session.response.body)['saved'].first['html']
      expect(html).to start_with('<div class="wiki">')
      expect(html).not_to match(/<a[^>]*href="javascript/)
      # Core's formatter sanitizes rather than escapes: the tags may stay, the
      # script vectors may not.
      expect(html).not_to match(/<img[^>]*onerror/)
    end
  end

  it 'does not write the note text to the log when the database rejects it' do
    issue = cma_issue(project: project)
    secret = 'secret-note-text'
    allow_any_instance_of(Issue).to receive(:save).and_raise(ActiveRecord::StatementInvalid, "INSERT ... '#{secret}'")
    logged = StringIO.new
    previous = Rails.logger
    Rails.logger = Logger.new(logged)

    results = RedmineContextMenuActions::IssueUpdater.new([issue], :user => user, :attributes => {'notes' => secret}).call

    expect(results.first.saved?).to be(false)
    expect(logged.string).to include('ActiveRecord::StatementInvalid')
    expect(logged.string).not_to include(secret)
  ensure
    Rails.logger = previous
  end
end
