# frozen_string_literal: true

require_relative 'spec_helper'

# Records what reaches core's bulk edit hook, so the specs can assert the hook
# fires once per issue with core's arguments. It can also play the concurrent
# user: bump the lock_version of the issue about to be saved.
class CmaHookProbe < Redmine::Hook::Listener
  class << self
    # stale_times: saves to make stale. delete_ids: issues another user deletes
    # while the first issue is saved. touch_ids: issues to change behind the back
    # of the first save, as a rescheduled follower or a recalculated parent would be.
    attr_accessor :calls, :stale_times, :delete_ids, :touch_ids

    def reset
      self.calls = []
      self.stale_times = 0
      self.delete_ids = []
      self.touch_ids = []
    end
  end
  reset

  def controller_issues_bulk_edit_before_save(context = {})
    self.class.calls << context
    issue = context[:issue]
    touch = self.class.touch_ids - [issue.id]
    Issue.where(:id => touch).update_all(['lock_version = lock_version + 1']) if touch.any?
    self.class.touch_ids = []
    gone = self.class.delete_ids - [issue.id]
    Issue.where(:id => gone).delete_all if gone.any?
    self.class.delete_ids = []
    return unless self.class.stale_times.positive?

    self.class.stale_times -= 1
    Issue.where(:id => issue.id).update_all(['lock_version = lock_version + 1'])
  end
end

RSpec.describe 'Add a note endpoint' do
  let(:project) { Project.find(1) }
  let(:session) { cma_session }
  let(:notes_only) { [:view_issues, :add_issue_notes] }

  before { CmaHookProbe.reset }
  after { CmaHookProbe.reset }

  def login_as(permissions, user: cma_user, projects: [project])
    projects.each { |p| cma_member(user, p, permissions) }
    cma_login(session, user.login, 'cmaPassword1!')
    user
  end

  def post_note(ids, notes, extra = {})
    session.post '/context_menu_actions/notes', :params => {:ids => ids, :notes => notes}.merge(extra), :xhr => true
    session.response
  end

  def journals_of(issue)
    Journal.where(:journalized_type => 'Issue', :journalized_id => issue.id).order(:id)
  end

  # The JSON the JavaScript response hands to RedmineContextMenuActions.saved.
  def payload(response = session.response)
    cma_saved_payload(response.body)
  end

  describe 'permissions' do
    it 'lets a user with only add_issue_notes add a note, where core bulk edit refuses' do
      user = login_as(notes_only)
      issue = cma_issue(project: project)

      session.post '/issues/bulk_update', :params => {:ids => [issue.id], :notes => 'via bulk'}
      expect(session.response.status).to eq(403)

      expect { post_note([issue.id], 'From the meeting') }.to change { journals_of(issue).count }.by(1)
      expect(session.response.status).to eq(200)
      journal = journals_of(issue).last
      expect(journal.user).to eq(user)
      expect(journal.notes).to eq('From the meeting')
      expect(journal.private_notes).to be(false)
    end

    it 'refuses a user without add_issue_notes, and writes nothing' do
      login_as([:view_issues, :edit_issues])
      issue = cma_issue(project: project)

      expect { post_note([issue.id], 'nope') }.not_to(change { journals_of(issue).count })
      expect(session.response.status).to eq(403)
    end

    it 'refuses the whole selection when one issue does not allow notes' do
      user = login_as(notes_only)
      other = Project.find(2)
      cma_member(user, other, [:view_issues])
      mine = cma_issue(project: project)
      theirs = cma_issue(project: other)

      expect { post_note([mine.id, theirs.id], 'nope') }.not_to(change { Journal.count })
      expect(session.response.status).to eq(403)
    end

    it 'answers 404 for an issue that does not exist' do
      login_as(notes_only)
      expect(post_note([999_999], 'x').status).to eq(404)
    end

    it 'answers 403 for an issue the user cannot see' do
      login_as(notes_only)
      hidden = cma_issue(project: Project.find(2)) # private project, not a member

      expect { post_note([hidden.id], 'x') }.not_to(change { Journal.count })
      expect(session.response.status).to eq(403)
    end

    it 'refuses an issue of an archived project' do
      login_as(notes_only)
      issue = cma_issue(project: project)
      project.update_column(:status, Project::STATUS_ARCHIVED)

      expect { post_note([issue.id], 'x') }.not_to(change { Journal.count })
      expect(session.response.status).to eq(403)
    end

    it 'refuses an issue of a closed project, as core does for notes' do
      login_as(notes_only)
      issue = cma_issue(project: project)
      project.update_column(:status, Project::STATUS_CLOSED)

      expect { post_note([issue.id], 'x') }.not_to(change { Journal.count })
      expect(session.response.status).to eq(403)
    end

    # Core lets the Anonymous role add notes on the issue page when it has
    # add_issue_notes, so the context menu does too.
    it 'treats an anonymous user as core does: allowed with the permission' do
      issue = cma_issue(project: project)
      expect(Role.anonymous.permissions).to include(:add_issue_notes)

      expect { post_note([issue.id], 'From a guest') }.to change { journals_of(issue).count }.by(1)
      expect(journals_of(issue).last.user).to eq(User.anonymous)
    end

    it 'asks an anonymous user without the permission to log in' do
      Role.anonymous.remove_permission!(:add_issue_notes)
      issue = cma_issue(project: project)

      expect { post_note([issue.id], 'x') }.not_to(change { Journal.count })
      expect(session.response.status).to eq(401)
    end

    it 'answers 404 when the action is switched off' do
      login_as(notes_only)
      issue = cma_issue(project: project)
      cma_settings('enable_notes' => '0')

      expect(post_note([issue.id], 'x').status).to eq(404)
    end
  end

  describe 'private notes' do
    it 'stores the note as private with set_notes_private' do
      login_as(notes_only + [:set_notes_private])
      issue = cma_issue(project: project)

      post_note([issue.id], 'Only for us', :issue => {:private_notes => '1'})
      expect(journals_of(issue).last.private_notes).to be(true)
    end

    # Rejected rather than ignored: ignoring would publish a note its author
    # meant for fewer readers.
    it 'refuses a private note without set_notes_private, instead of publishing it' do
      login_as(notes_only)
      issue = cma_issue(project: project)

      expect { post_note([issue.id], 'Only for us', :issue => {:private_notes => '1'}) }.not_to(change { Journal.count })
      expect(session.response.status).to eq(200)
      expect(payload['saved']).to eq([])
      expect(payload['failed']).to eq([issue.id])
      expect(payload['errorsHtml']).to include(I18n.t(:notice_not_authorized))
    end

    it 'shows the author their own private note in the Last notes row' do
      login_as(notes_only + [:set_notes_private])
      issue = cma_issue(project: project)

      post_note([issue.id], 'Private remark', :issue => {:private_notes => '1'}, :c => %w[subject last_notes])
      expect(payload['saved'].first['html']).to include('Private remark')
    end
  end

  describe 'the note itself' do
    before { login_as(notes_only) }

    let(:issue) { cma_issue(project: project) }

    ['', '   ', "\n\t \n"].each do |blank|
      it "refuses a blank note (#{blank.inspect}) and writes nothing" do
        expect { post_note([issue.id], blank) }.not_to(change { Journal.count })
        expect(payload['failed']).to eq([issue.id])
        expect(payload['errorsHtml']).to include('errorExplanation')
        expect(payload['errorsHtml']).to include(ERB::Util.html_escape("#{I18n.t(:field_notes)} #{I18n.t('activerecord.errors.messages.blank')}"))
      end
    end

    it 'keeps the text exactly as typed, leading spaces and markup included' do
      text = "  indented\n\n*bold* and <b>tag</b>"
      post_note([issue.id], text)
      expect(journals_of(issue).last.notes).to eq(text)
    end

    it 'accepts a very long note' do
      text = 'x' * 60_000
      post_note([issue.id], text)
      expect(journals_of(issue).last.notes.size).to eq(60_000)
    end

    it 'updates updated_on, as a note added in core does' do
      issue.update_column(:updated_on, 2.days.ago)
      post_note([issue.id], 'touch')
      expect(issue.reload.updated_on).to be > 1.minute.ago
    end
  end

  describe 'several issues' do
    let(:user) { cma_user }

    before { login_as(notes_only, user: user) }

    it 'adds exactly one journal to each issue' do
      issues = Array.new(3) { cma_issue(project: project) }

      post_note(issues.map(&:id), 'Discussed in the meeting')
      issues.each { |issue| expect(journals_of(issue).pluck(:notes)).to eq(['Discussed in the meeting']) }
      expect(payload['saved'].map { |s| s['id'] }).to eq(issues.map(&:id))
      expect(payload['failed']).to eq([])
    end

    it 'adds notes across projects when every issue allows it' do
      other = Project.find(3)
      cma_member(user, other, notes_only)
      a = cma_issue(project: project)
      b = cma_issue(project: other)

      post_note([a.id, b.id], 'Both projects')
      expect(journals_of(a).count).to eq(1)
      expect(journals_of(b).count).to eq(1)
    end

    # A due date the workflow requires is validated on every save by a user whose
    # role follows the workflow (core's validate_required_fields), so one issue
    # without a due date fails while the other saves.
    describe 'when one of them cannot be saved' do
      let!(:valid) { cma_issue(project: project, due_date: Date.today + 7) }
      let!(:invalid) { cma_issue(project: project) }

      before do
        role = Member.find_by(:user_id => user.id, :project_id => project.id).roles.first
        role.add_permission!(:edit_issues)
        WorkflowPermission.create!(:role_id => role.id, :tracker_id => invalid.tracker_id,
                                   :old_status_id => invalid.status_id, :field_name => 'due_date', :rule => 'required')
      end

      it 'saves the valid one, reports the other per issue, and writes no second note on retry' do
        post_note([valid.id, invalid.id], 'Partial')

        expect(journals_of(valid).count).to eq(1)
        expect(journals_of(invalid).count).to eq(0)
        expect(payload['saved'].map { |s| s['id'] }).to eq([valid.id])
        expect(payload['failed']).to eq([invalid.id])
        blank = "#{I18n.t(:field_due_date)} #{I18n.t('activerecord.errors.messages.blank')}"
        expect(payload['errorsHtml']).to include("##{invalid.id}: #{blank}")
        expect(payload['errorsHtml']).to include(I18n.t(:notice_failed_to_save_issues, :count => 1, :total => 2, :ids => "##{invalid.id}"))
        # The line a closed dialog's late answer shows as a notice.
        expect(payload['errorText']).to eq(I18n.t(:notice_failed_to_save_issues, :count => 1, :total => 2, :ids => "##{invalid.id}"))
        # The form is narrowed to the issue that failed.
        expect(payload['idsHtml']).to include(%(value="#{invalid.id}"))
        expect(payload['idsHtml']).not_to include(%(value="#{valid.id}"))
        expect(payload['summaryHtml']).to include("##{invalid.id}")

        invalid.update_column(:due_date, Date.today + 3)
        post_note(payload['failed'], 'Partial')

        expect(journals_of(valid).count).to eq(1)
        expect(journals_of(invalid).count).to eq(1)
      end
    end
  end

  describe 'a concurrent update' do
    before { login_as(notes_only) }

    # Aged, so the save really updates the row: on MySQL, whose datetimes have
    # whole seconds, a note added in the second the issue was created leaves
    # updated_on unchanged, and core then writes the journal without touching the
    # issue row or its lock_version at all.
    let(:issue) do
      issue = cma_issue(project: project)
      issue.update_column(:updated_on, 1.hour.ago)
      issue
    end

    it 'retries once on a stale object and writes one journal' do
      CmaHookProbe.stale_times = 1

      post_note([issue.id], 'After a conflict')
      expect(journals_of(issue).pluck(:notes)).to eq(['After a conflict'])
      expect(payload['failed']).to eq([])
    end

    it 'reports a second conflict instead of retrying forever' do
      CmaHookProbe.stale_times = 2

      post_note([issue.id], 'Conflict twice')
      expect(journals_of(issue).count).to eq(0)
      expect(payload['failed']).to eq([issue.id])
      expect(payload['errorsHtml']).to include(ERB::Util.html_escape(I18n.t(:notice_issue_update_conflict)))
    end

    # Core's bulk_update reloads each issue before it changes it: a save earlier
    # in the loop can change a later issue (a rescheduled follower, a parent).
    it 'reloads each issue before saving it, so a change made by an earlier save is no conflict' do
      first = issue
      later = cma_issue(project: project)
      later.update_column(:updated_on, 1.hour.ago)
      CmaHookProbe.touch_ids = [later.id]

      post_note([first.id, later.id], 'In order')
      expect(payload['failed']).to eq([])
      expect(journals_of(later).pluck(:notes)).to eq(['In order'])
      # Once each: no stale retry for the later issue.
      expect(CmaHookProbe.calls.map { |c| c[:issue].id }).to eq([first.id, later.id])
    end

    # Another user deletes an issue while the one before it is saved. The issues
    # before it are saved and must not be submitted again, so this is a failure
    # of that issue only, not a 404.
    it 'reports an issue deleted during the request for that issue only, and saves the others once' do
      kept = issue # created first, so saved first
      deleted = cma_issue(project: project)
      deleted.update_column(:updated_on, 1.hour.ago)
      CmaHookProbe.delete_ids = [deleted.id]

      post_note([kept.id, deleted.id], 'Still here?')
      expect(session.response.status).to eq(200)
      expect(Issue.exists?(deleted.id)).to be(false)
      expect(CmaHookProbe.calls.map { |c| c[:issue].id }).to eq([kept.id])
      expect(payload['saved'].map { |s| s['id'] }).to eq([kept.id])
      expect(payload['failed']).to eq([deleted.id])
      expect(journals_of(kept).count).to eq(1)
      expect(payload['idsHtml']).to include(%(value="#{deleted.id}"))
      expect(payload['idsHtml']).not_to include(%(value="#{kept.id}"))
    end
  end

  # The page applies an answer to the dialog that sent it, and to no other.
  describe 'the dialog an answer belongs to' do
    before { login_as(notes_only) }

    let(:issue) { cma_issue(project: project) }

    it 'echoes the token of the dialog' do
      post_note([issue.id], 'Mine', :cma_dialog => 'd3-lx2k9a')
      expect(payload['dialog']).to eq('d3-lx2k9a')
    end

    it 'echoes nothing for a missing or malformed token' do
      post_note([issue.id], 'No token')
      expect(payload['dialog']).to be_nil
      post_note([issue.id], 'Bad token', :cma_dialog => '</script><b>x')
      expect(payload['dialog']).to be_nil
      expect(session.response.body).not_to include('<b>x')
    end
  end

  # A response lost on the way back (Wi-Fi, a proxy timeout) leaves the dialog
  # open with the text; the user submits again. The note must not be added twice
  # to the issues the first request already saved.
  describe 'a second submit of the same dialog' do
    let(:user) { login_as(notes_only) }
    let(:issue) { cma_issue(project: project) }
    let(:since) { 1.minute.ago.to_i }

    before { user }

    it 'reports the issue as saved without adding the note again' do
      post_note([issue.id], 'Only once', :cma_since => since)
      post_note([issue.id], 'Only once', :cma_since => since)

      expect(journals_of(issue).pluck(:notes)).to eq(['Only once'])
      expect(payload['saved'].map { |s| s['id'] }).to eq([issue.id])
      expect(payload['failed']).to eq([])
    end

    it 'adds the note only to the issues that do not have it yet' do
      other = cma_issue(project: project)
      post_note([issue.id], 'Second half', :cma_since => since)
      post_note([issue.id, other.id], 'Second half', :cma_since => since)

      expect(journals_of(issue).count).to eq(1)
      expect(journals_of(other).pluck(:notes)).to eq(['Second half'])
      expect(payload['saved'].map { |s| s['id'] }.sort).to eq([issue.id, other.id].sort)
    end

    it 'adds a different text, or the same text in another case' do
      post_note([issue.id], 'Agreed', :cma_since => since)
      post_note([issue.id], 'agreed', :cma_since => since)
      post_note([issue.id], 'Agreed.', :cma_since => since)

      expect(journals_of(issue).pluck(:notes)).to eq(['Agreed', 'agreed', 'Agreed.'])
    end

    it 'adds the same text again from a dialog opened after the first note' do
      post_note([issue.id], 'Again', :cma_since => since)
      journals_of(issue).update_all(:created_on => 2.minutes.ago)
      post_note([issue.id], 'Again', :cma_since => since)

      expect(journals_of(issue).count).to eq(2)
    end

    it 'adds the same text when another user wrote it' do
      Journal.create!(:journalized => issue, :user => User.find(2), :notes => 'Shared words')
      post_note([issue.id], 'Shared words', :cma_since => since)

      expect(journals_of(issue).where(:user_id => user.id).count).to eq(1)
    end

    it 'tells a private note from a public one with the same text' do
      Member.find_by(:user_id => user.id, :project_id => project.id).roles.first.add_permission!(:set_notes_private)
      post_note([issue.id], 'Same words', :cma_since => since)
      post_note([issue.id], 'Same words', :cma_since => since, :issue => {:private_notes => '1'})
      post_note([issue.id], 'Same words', :cma_since => since, :issue => {:private_notes => '1'})

      expect(journals_of(issue).pluck(:notes, :private_notes)).to eq([['Same words', false], ['Same words', true]])
    end

    # A second request for the same issue waits for the first to commit and
    # then finds its note: the issue is read for update before the check.
    it 'checks for the note on a copy of the issue locked for update' do
      sql = cma_queries { post_note([issue.id], 'Locked', :cma_since => since) }
      locked = sql.index { |q| q =~ /FROM ["`]?issues["`]? WHERE .*FOR UPDATE/i }
      checked = sql.index { |q| q =~ /FROM ["`]?journals["`]? WHERE .*created_on/i }

      expect(locked).not_to be_nil, sql.grep(/issues/i).join("\n")
      expect(checked).not_to be_nil
      expect(locked).to be < checked
    end

    it 'adds the note again without a dialog time, or with an implausible one' do
      post_note([issue.id], 'Plain')
      post_note([issue.id], 'Plain')
      post_note([issue.id], 'Plain', :cma_since => 2.days.ago.to_i)
      post_note([issue.id], 'Plain', :cma_since => 'yesterday')

      expect(journals_of(issue).count).to eq(4)
    end
  end

  describe 'parity with core' do
    before { login_as(notes_only) }

    let(:issue) { cma_issue(project: project) }

    it 'calls controller_issues_bulk_edit_before_save once per issue, with params and issue' do
      other = cma_issue(project: project)
      post_note([issue.id, other.id], 'hooked')

      expect(CmaHookProbe.calls.size).to eq(2)
      expect(CmaHookProbe.calls.map { |c| c[:issue].id }).to eq([issue.id, other.id].sort)
      expect(CmaHookProbe.calls.first[:params][:notes]).to eq('hooked')
      expect(CmaHookProbe.calls.first[:controller]).to be_a(ContextMenuActionsController)
    end

    # Core's bulk edit form always posts issue[...]; a hook that reads
    # params[:issue][...] must not fail on a note-only request.
    it 'gives the hook an issue parameter for a note-only request, as core bulk edit does' do
      post_note([issue.id], 'hooked')

      expect(CmaHookProbe.calls.first[:params][:issue][:status_id]).to be_nil
      expect(payload['failed']).to eq([])
    end

    it 'sends the notification mail core sends for a note' do
      Setting.notified_events = ['issue_note_added']
      watcher = User.find(3)
      Watcher.create!(:watchable => issue, :user => watcher)

      post_note([issue.id], 'Mail me')
      recipients = ActionMailer::Base.deliveries.flat_map { |mail| Array(mail.to) + Array(mail.bcc) }
      expect(recipients).to include(watcher.mail)
    end

    it 'sends no mail when notes are not a notified event' do
      Setting.notified_events = []
      post_note([issue.id], 'Quiet')
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'notifies a user mentioned with @login' do
      Setting.notified_events = ['issue_note_added']
      mentioned = User.find(3) # dlopper, member of the project, not watching
      mentioned.pref.update!(:no_self_notified => false)
      mentioned.update_column(:mail_notification, 'only_my_events')

      post_note([issue.id], "@#{mentioned.login} can you check this?")
      recipients = ActionMailer::Base.deliveries.flat_map { |mail| Array(mail.to) + Array(mail.bcc) }
      expect(recipients).to include(mentioned.mail)
    end
  end

  describe 'the Last notes row in the response' do
    before { login_as(notes_only) }

    let(:issue) { cma_issue(project: project) }

    it 'renders the note with core column markup, through the wiki formatter' do
      post_note([issue.id], "*Strong* <script>alert(1)</script>", :c => %w[subject last_notes])
      html = payload['saved'].first['html']

      expect(html).to start_with('<div class="wiki">')
      expect(html).not_to include('<script>')
      expect(payload['lastNotes']).to eq('order' => ['last_notes'], 'caption' => nil)
    end

    it 'gives the block order and a caption when the list shows several block columns' do
      post_note([issue.id], 'Ordered', :c => %w[subject description last_notes])
      expect(payload['lastNotes']).to eq('order' => %w[description last_notes], 'caption' => I18n.t(:label_last_notes))
    end

    it 'gives no layout when the list does not show Last notes' do
      post_note([issue.id], 'No block', :c => %w[subject])
      expect(payload['lastNotes']).to be_nil
      # Still the markup, for a Last notes row elsewhere on the page.
      expect(payload['saved'].first['html']).to include('No block')
    end

    it 'ignores a column parameter that is not a list of names' do
      post_note([issue.id], 'Odd columns', :c => {'x' => 'last_notes'})
      expect(session.response.status).to eq(200)
      expect(payload['lastNotes']).to be_nil
    end
  end

  describe 'without JavaScript' do
    before { login_as(notes_only) }

    let(:issue) { cma_issue(project: project) }

    it 'saves and redirects back with a flash' do
      session.post '/context_menu_actions/notes', :params => {:ids => [issue.id], :notes => 'Plain post'}
      expect(session.response).to be_redirect
      expect(session.flash[:notice]).to eq(I18n.t(:label_issue_note_added))
      expect(journals_of(issue).count).to eq(1)
    end

    it 'redirects back with the error' do
      session.post '/context_menu_actions/notes', :params => {:ids => [issue.id], :notes => ' '}
      expect(session.response).to be_redirect
      expect(session.flash[:error]).to be_present
    end

    it 'sends the dialog request to the issue page' do
      session.get '/context_menu_actions/notes/new', :params => {:ids => [issue.id]}
      expect(session.response.status).to eq(302)
      expect(session.response.location).to end_with("/issues/#{issue.id}/edit")
    end
  end

  describe 'CSRF' do
    # Logged in first: the login form itself would need a token otherwise.
    it 'refuses a POST without the authenticity token' do
      login_as(notes_only)
      issue = cma_issue(project: project)
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      expect { post_note([issue.id], 'forged') }.not_to(change { Journal.count })
      expect(session.response.status).to eq(422)
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end
  end
end
