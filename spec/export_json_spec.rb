# frozen_string_literal: true

require_relative 'spec_helper'

# The JSON export. Every entry must be what GET /issues/:id.json?include=...
# answers the same user, so the examples that matter compare the file with the
# real API response, issue by issue, byte for byte: whatever core or another
# plugin hides from that user in the API is hidden in the file as well.
RSpec.describe 'Export (JSON)' do
  PASSWORD = 'cmaPassword1!'
  ALL_PARTS = 'journals,attachments,relations,children,watchers,changesets'

  let(:project) { Project.find(1) }
  let(:private_project) { Project.find(2) }

  before do
    cma_settings('enable_export_json' => '1')
    with_settings_rest_api
  end

  def with_settings_rest_api
    Setting.rest_api_enabled = '1'
  end

  def export(session, ids, extra = {})
    session.get '/context_menu_actions/export', :params => {:ids => ids}.merge(extra)
    session.response
  end

  def login(user)
    cma_login(cma_session, user.login, PASSWORD)
  end

  def api_get(user, id, include = ALL_PARTS)
    api = cma_session
    api.get "/issues/#{id}.json", :params => {:include => include}, :headers => {'X-Redmine-API-Key' => user.api_key}
    api.response
  end

  # The oracle. For each id: 200 from the API means the file holds the very same
  # bytes; 403 and 404 mean the issue is skipped with that reason.
  def expect_export_to_match_api(user, ids, include: ALL_PARTS)
    response = export(login(user), ids)
    expect(response.status).to eq(200), response.body[0, 300]
    raw = response.body
    document = JSON.parse(raw)
    exported = document['issues'].index_by { |entry| entry['id'] }
    skipped = document['skipped'].to_h { |entry| [entry['id'], entry['reason']] }

    statuses = ids.to_h do |id|
      api = api_get(user, id, include)
      case api.status
      when 200
        inner = api.body.delete_prefix('{"issue":').delete_suffix('}')
        expect(raw).to include(inner), "issue ##{id} differs from the API for #{user.login}"
        expect(exported[id]).to eq(JSON.parse(api.body)['issue'])
        expect(skipped).not_to have_key(id)
      when 403
        expect(skipped[id]).to eq('forbidden'), "issue ##{id}"
        expect(exported).not_to have_key(id)
      when 404
        expect(skipped[id]).to eq('not_found'), "issue ##{id}"
        expect(exported).not_to have_key(id)
      else
        raise "unexpected API status #{api.status} for issue ##{id}"
      end
      [id, api.status]
    end
    expect(exported.size + skipped.size).to eq(ids.uniq.size)
    [document, statuses]
  end

  def ifv_hides_api_values?
    Redmine::Plugin.installed?(:redmine_issue_field_visibility) && RedmineIssueFieldVisibility.respond_to?(:hide_values)
  end

  def exporter(permissions, projects: [project], issues_visibility: 'all')
    user = cma_user
    projects.each { |p| cma_member(user, p, permissions | [:export_issues_json], issues_visibility: issues_visibility) }
    user
  end

  # A fresh copy each time: init_journal keeps the journal of the last save on
  # the same object.
  def private_note(issue, author, text)
    issue = Issue.find(issue.id)
    journal = issue.init_journal(author, text)
    journal.private_notes = true
    issue.save!
    journal
  end

  def public_note(issue, author, text)
    issue = Issue.find(issue.id)
    issue.init_journal(author, text)
    issue.save!
  end

  # Issues with every part the API can include: journals with public and private
  # notes and field changes, an attachment, a relation, a child, a watcher.
  let!(:rich_issue) do
    issue = cma_issue(project: project, subject: 'Rich', description: 'Description of the rich issue',
                      start_date: Date.new(2026, 1, 5), estimated_hours: 3.5)
    public_note(issue, User.find(2), 'A public note')
    private_note(issue, User.find(2), 'A private note of jsmith')
    issue = Issue.find(issue.id)
    issue.init_journal(User.find(2))
    issue.due_date = Date.new(2026, 2, 1)
    issue.save!
    Attachment.create!(:container => issue, :author => User.find(2), :filename => 'export.txt',
                       :disk_filename => '260105000000_export.txt', :filesize => 12, :content_type => 'text/plain',
                       :digest => '0' * 64, :description => 'metadata only')
    cma_issue(project: project, subject: 'Child', parent_issue_id: issue.id)
    IssueRelation.create!(:issue_from => issue, :issue_to => Issue.find(2), :relation_type => 'relates')
    Watcher.create!(:watchable => issue, :user => User.find(3))
    issue.reload
  end

  let(:private_issue) { cma_issue(project: project, subject: 'Private', is_private: true, author: User.find(2)) }
  let(:invisible_issue) { cma_issue(project: private_project, subject: 'Elsewhere') }
  let(:missing_id) { Issue.maximum(:id) + 1000 }
  let(:fixture_ids) { Issue.where(:project_id => project.id).order(:id).limit(8).pluck(:id) }
  let(:ids) { ([rich_issue.id, private_issue.id, invisible_issue.id, missing_id] + fixture_ids).uniq }

  describe 'the file, compared with GET /issues/:id.json for the same user' do
    it 'is the API for a manager' do
      user = exporter(Role.find(1).permissions)
      document, statuses = expect_export_to_match_api(user, ids)

      expect(statuses[rich_issue.id]).to eq(200)
      expect(statuses[private_issue.id]).to eq(200)
      expect(statuses[invisible_issue.id]).to eq(403)
      expect(statuses[missing_id]).to eq(404)
      notes = document['issues'].detect { |i| i['id'] == rich_issue.id }['journals'].map { |j| j['notes'] }
      expect(notes).to include('A private note of jsmith')
    end

    it 'is the API for a reporter, with private notes on the issues' do
      user = exporter(Role.find(3).permissions, issues_visibility: 'default')
      private_note(rich_issue, user, 'My own private note')
      document, statuses = expect_export_to_match_api(user, ids)

      expect(statuses[private_issue.id]).to eq(403)
      notes = document['issues'].detect { |i| i['id'] == rich_issue.id }['journals'].map { |j| j['notes'] }
      expect(notes).to include('My own private note', 'A public note')
      expect(notes).not_to include('A private note of jsmith')
    end

    it 'is the API for a user without view_private_notes, and holds no private note of others' do
      user = exporter([:view_issues, :view_issue_watchers, :view_time_entries, :view_changesets])
      document, = expect_export_to_match_api(user, ids)

      expect(document.to_json).not_to include('A private note of jsmith')
      entry = document['issues'].detect { |i| i['id'] == rich_issue.id }
      expect(entry['journals'].map { |j| j['notes'] }).to include('A public note')
    end

    it 'is the API for a user who reads comments newest first, in another time zone and language' do
      user = exporter(Role.find(1).permissions)
      user.pref.update!(:comments_sorting => 'desc', :time_zone => 'Tokyo')
      user.update!(:language => 'de')

      expect_export_to_match_api(user, ids)
    end

    it 'is the API without watchers, time entries and changesets permissions' do
      user = exporter([:view_issues])
      document, = expect_export_to_match_api(user, ids)

      entry = document['issues'].detect { |i| i['id'] == rich_issue.id }
      expect(entry).not_to have_key('watchers')
      expect(entry).not_to have_key('spent_hours')
    end

    it 'is the API for custom fields visible to some roles only, and their journal details' do
      user = exporter([:view_issues])
      other_role = Role.find(1)
      field = IssueCustomField.create!(:name => 'cma secret', :field_format => 'string', :is_for_all => true,
                                       :trackers => Tracker.all, :visible => false, :role_ids => [other_role.id])
      open = IssueCustomField.create!(:name => 'cma open', :field_format => 'string', :is_for_all => true,
                                      :trackers => Tracker.all, :visible => true)
      issue = Issue.find(rich_issue.id)
      issue.init_journal(User.find(1))
      issue.custom_field_values = {field.id.to_s => 'hidden value', open.id.to_s => 'open value'}
      issue.save!

      document, = expect_export_to_match_api(user, ids)
      text = document.to_json
      expect(text).not_to include('hidden value')
      expect(text).not_to include('cma secret')
      expect(text).to include('open value')
    end

    it 'is the API for the parts the settings include' do
      cma_settings('export_json_include' => %w[journals watchers])
      user = exporter(Role.find(1).permissions)
      document, = expect_export_to_match_api(user, ids, include: 'journals,watchers')

      entry = document['issues'].detect { |i| i['id'] == rich_issue.id }
      expect(entry).to have_key('journals')
      expect(entry).not_to have_key('attachments')
      expect(entry).not_to have_key('relations')
    end

    it 'is the API with no part included at all' do
      cma_settings('export_json_include' => [''])
      user = exporter(Role.find(1).permissions)
      expect_export_to_match_api(user, ids, include: '')
    end

    it 'is the API for an administrator' do
      admin = User.find(1)
      admin.password = PASSWORD
      admin.password_confirmation = PASSWORD
      admin.save!
      expect_export_to_match_api(admin, ids + [invisible_issue.id])
    end
  end

  describe 'issues the user may not open' do
    it 'skips an issue the user cannot see, and one that does not exist' do
      user = exporter([:view_issues])
      document = JSON.parse(export(login(user), [rich_issue.id, invisible_issue.id, missing_id]).body)

      expect(document['issues'].map { |i| i['id'] }).to eq([rich_issue.id])
      expect(document['skipped']).to eq([{'id' => invisible_issue.id, 'reason' => 'forbidden'},
                                         {'id' => missing_id, 'reason' => 'not_found'}])
      expect(document.to_json).not_to include('Elsewhere')
    end

    it 'skips a private issue of someone else for a role that sees its own issues only' do
      user = exporter([:view_issues], issues_visibility: 'own')
      own = cma_issue(project: project, author: user, subject: 'Mine')
      document = JSON.parse(export(login(user), [own.id, private_issue.id]).body)

      expect(document['issues'].map { |i| i['id'] }).to eq([own.id])
      expect(document['skipped']).to eq([{'id' => private_issue.id, 'reason' => 'forbidden'}])
    end

    # redmine_view_issue_description refuses the issue page and the API show to
    # a user who may not open the issue (vid_authorize_issue_detail). The export
    # asks the same question, Issue#detail_access_granted?.
    describe 'an issue redmine_view_issue_description refuses' do
      def without_description_permission(user)
        Member.where(:user_id => user.id).flat_map(&:roles).each do |role|
          role.remove_permission!(:view_issue_description)
        end
        user.reload
      end

      it 'is skipped, as the API refuses it' do
        user = exporter([:view_issues])
        if Redmine::Plugin.installed?(:redmine_view_issue_description)
          without_description_permission(user)
          _, statuses = expect_export_to_match_api(user, [rich_issue.id])
          expect(statuses[rich_issue.id]).to eq(403)
        else
          Issue.class_eval { def detail_access_granted?(_user) = subject != 'Rich' }
          begin
            document = JSON.parse(export(login(user), [rich_issue.id, private_issue.id]).body)
            expect(document['issues'].map { |i| i['id'] }).to eq([private_issue.id])
            expect(document['skipped']).to eq([{'id' => rich_issue.id, 'reason' => 'forbidden'}])
          ensure
            Issue.send(:remove_method, :detail_access_granted?)
          end
        end
      end

      it 'is exported to its assignee, as the API shows it' do
        skip 'redmine_view_issue_description is not installed' unless Redmine::Plugin.installed?(:redmine_view_issue_description)
        user = exporter([:view_issues])
        without_description_permission(user)
        rich_issue.update_column(:assigned_to_id, user.id)

        _, statuses = expect_export_to_match_api(user, [rich_issue.id])
        expect(statuses[rich_issue.id]).to eq(200)
      end
    end

    # redmine_issue_field_visibility hides core fields per role. The version with
    # hide_values (7.0) hides them in the API view too, and the file hides them
    # the same way.
    it 'leaves out the core fields redmine_issue_field_visibility hides' do
      skip 'redmine_issue_field_visibility with hide_values is not installed' unless ifv_hides_api_values?
      user = exporter([:view_issues])
      role = Member.find_by(:user_id => user.id, :project_id => project.id).roles.first
      Setting.plugin_redmine_issue_field_visibility = {
        'hiddenfields' => {role.id.to_s => {'estimated_hours' => '1', 'due_date' => '1', 'start_date' => '1'}}
      }

      document, = expect_export_to_match_api(user, ids)
      entry = document['issues'].detect { |i| i['id'] == rich_issue.id }
      expect(entry['estimated_hours']).to be_nil
      expect(entry['start_date']).to be_nil
      details = entry['journals'].flat_map { |j| j['details'] }.map { |d| d['name'] }
      expect(details).not_to include('due_date')
    end

    # The version without hide_values (5.1) hides core fields in the UI only; its
    # API view still shows them. The REST API may be off, so the file must not
    # show what the UI hides: an issue with a core field hidden from the user is
    # refused as one the user may not open. Without the plugin, a stand-in with
    # the same hidden_core_fields runs the same examples.
    describe 'redmine_issue_field_visibility without hide_values' do
      before do
        skip 'redmine_issue_field_visibility has hide_values: the API view hides the fields' if ifv_hides_api_values?
      end

      # The plugin's own setting when it is installed; otherwise the stand-in
      # reads the same structure from here.
      def hide_fields(role, fields)
        hidden = {'hiddenfields' => {role.id.to_s => fields.index_with { '1' }}}
        if Redmine::Plugin.installed?(:redmine_issue_field_visibility)
          Setting.plugin_redmine_issue_field_visibility = hidden
        else
          @ifv_settings = hidden
        end
      end

      def with_ifv(&block)
        return yield if Redmine::Plugin.installed?(:redmine_issue_field_visibility)

        settings = @ifv_settings || {}
        stand_in = Module.new
        stand_in.define_singleton_method(:hidden_core_fields) do |user = User.current, project = nil|
          next [] if user.admin?

          lists = user.roles_for_project(project).map do |role|
            (settings['hiddenfields'][role.id.to_s] || {}).select { |_, value| value.to_s == '1' }.keys
          end
          lists.inject { |a, b| a & b } || []
        end
        Object.const_set(:RedmineIssueFieldVisibility, stand_in)
        begin
          block.call
        ensure
          Object.send(:remove_const, :RedmineIssueFieldVisibility)
        end
      end

      it 'refuses an issue with a core field hidden from the user' do
        user = exporter([:view_issues])
        hide_fields(Member.find_by(:user_id => user.id, :project_id => project.id).roles.first, %w[estimated_hours])

        with_ifv do
          document = JSON.parse(export(login(user), [rich_issue.id]).body)
          expect(document['issues']).to eq([])
          expect(document['skipped']).to eq([{'id' => rich_issue.id, 'reason' => 'forbidden'}])
          expect(document.to_json).not_to include('Description of the rich issue')
        end
      end

      it 'exports the issue as the API shows it to a role without hidden fields' do
        user = exporter([:view_issues])
        hide_fields(Role.find(1), %w[estimated_hours])

        with_ifv do
          _, statuses = expect_export_to_match_api(user, [rich_issue.id])
          expect(statuses[rich_issue.id]).to eq(200)
        end
      end

      it 'exports everything to an administrator' do
        admin = User.find(1)
        admin.password = PASSWORD
        admin.password_confirmation = PASSWORD
        admin.save!
        hide_fields(Role.find(1), %w[estimated_hours])

        with_ifv do
          _, statuses = expect_export_to_match_api(admin, [rich_issue.id])
          expect(statuses[rich_issue.id]).to eq(200)
        end
      end
    end
  end

  describe 'the response' do
    let(:user) { exporter([:view_issues]) }

    it 'is a JSON attachment that is not cached' do
      response = export(login(user), [rich_issue.id])

      expect(response.status).to eq(200)
      expect(response.media_type).to eq('application/json')
      expect(response.headers['Content-Disposition']).to match(/\Aattachment; filename="issues-\d{8}-\d{6}\.json"/)
      expect(response.headers['Cache-Control']).to include('no-store')
    end

    it 'wraps the issues with when, by whom and on which Redmine' do
      document = JSON.parse(export(login(user), [rich_issue.id]).body)

      expect(document.keys).to eq(%w[exported_on exported_by redmine_version issues skipped])
      expect(Time.iso8601(document['exported_on'])).to be_within(1.minute).of(Time.now)
      expect(document['exported_by']).to eq('id' => user.id, 'name' => user.name)
      expect(document['redmine_version']).to eq(Redmine::VERSION.to_s)
      expect(document['skipped']).to eq([])
    end

    it 'never wraps the file in a JSONP callback' do
      Setting.jsonp_enabled = '1'
      response = export(login(user), [rich_issue.id], :callback => 'steal', :jsonp => 'steal')

      expect(response.media_type).to eq('application/json')
      expect(response.body).to start_with('{"exported_on":')
    end

    # export_issues_json is a read permission, like view_issues. Whatever the API
    # still shows on a closed project, the file holds. (redmine_view_issue_description
    # refuses the issue there: its permission is not a read permission.)
    it 'exports the issues of a closed project as the API shows them' do
      project.update_column(:status, Project::STATUS_CLOSED)
      _, statuses = expect_export_to_match_api(user, [rich_issue.id])

      expect(statuses[rich_issue.id]).to eq(200) unless Redmine::Plugin.installed?(:redmine_view_issue_description)
    end

    it 'leaves the session usable: the next page is HTML again' do
      session = login(user)
      export(session, [rich_issue.id])
      session.get "/issues/#{rich_issue.id}"

      expect(session.response.status).to eq(200)
      expect(session.response.media_type).to eq('text/html')
    end
  end

  describe 'refusals' do
    it 'answers 404 while the export is switched off' do
      cma_settings('enable_export_json' => '0')
      user = exporter([:view_issues])

      expect(export(login(user), [rich_issue.id]).status).to eq(404)
    end

    it 'answers 403 without export_issues_json' do
      user = cma_user
      cma_member(user, project, [:view_issues])

      expect(export(login(user), [rich_issue.id]).status).to eq(403)
    end

    it 'answers 403 when one visible issue is in a project without export_issues_json' do
      user = exporter([:view_issues])
      cma_member(user, private_project, [:view_issues])

      expect(export(login(user), [rich_issue.id, invisible_issue.id]).status).to eq(403)
    end

    it 'answers 403 when none of the issues is visible' do
      user = exporter([:view_issues])

      expect(export(login(user), [invisible_issue.id]).status).to eq(403)
    end

    it 'answers 404 without ids, or with ids that do not exist' do
      user = exporter([:view_issues])
      session = login(user)

      expect(export(session, []).status).to eq(404)
      expect(export(session, [missing_id]).status).to eq(404)
      expect(export(session, ['x', {'a' => 'b'}]).status).to eq(404)
      expect(export(session, ['99999999999', '2147483648', '0', '-1']).status).to eq(404)
    end

    it 'ignores ids it cannot use next to ones it can' do
      user = exporter([:view_issues])
      document = JSON.parse(export(login(user), [rich_issue.id.to_s, '2147483648', 'x']).body)

      expect(document['issues'].map { |i| i['id'] }).to eq([rich_issue.id])
      expect(document['skipped']).to eq([])
    end

    it 'sends an anonymous user to the login page when Redmine requires a login' do
      Setting.login_required = '1'
      response = export(cma_session, [rich_issue.id])

      expect(response.status).to eq(302)
      expect(response.location).to include('/login')
    end

    it 'ignores an API key: the export is for the signed in user only' do
      user = exporter([:view_issues])
      session = cma_session
      [{}, {:format => 'json'}].each do |extra|
        session.get '/context_menu_actions/export', :params => {:ids => [rich_issue.id], :key => user.api_key}.merge(extra)
        expect(session.response.status).not_to eq(200)
        session.get '/context_menu_actions/export', :params => {:ids => [rich_issue.id]}.merge(extra),
                                                    :headers => {'X-Redmine-API-Key' => user.api_key}
        expect(session.response.status).not_to eq(200)
      end
    end

    describe 'over the limit' do
      let(:user) { exporter([:view_issues]) }
      let(:many) { Array.new(3) { cma_issue(project: project) }.map(&:id) }

      before { cma_settings('export_json_limit' => '2') }

      it 'sends no file and says why' do
        session = login(user)
        response = export(session, many, :back_url => '/projects/ecookbook/issues')

        expect(response.status).to eq(302)
        expect(response.location).to end_with('/projects/ecookbook/issues')
        expect(response.headers['Content-Disposition']).to be_nil
        expect(session.flash[:error]).to eq(I18n.t(:text_cma_export_limit_exceeded, :count => 3, :max => 2))
      end

      it 'exports exactly the limit' do
        expect(export(login(user), many.first(2)).status).to eq(200)
      end

      it 'counts an id given twice once' do
        expect(export(login(user), many.first(2) * 2).status).to eq(200)
      end
    end
  end

  describe 'the context menu' do
    def menu(user, issue_ids)
      session = login(user)
      session.get '/issues/context_menu', :params => {:ids => issue_ids, :back_url => '/issues'}, :xhr => true
      expect(session.response.status).to eq(200)
      session.response.body[%r{<a [^>]*href="/context_menu_actions/export[^"]*"[^>]*>.*?</a>}m]
    end

    it 'offers Export (JSON) as a plain download link for the selected issues' do
      other = cma_issue(project: project)
      link = menu(exporter([:view_issues]), [rich_issue.id, other.id])

      expect(link).to include("ids%5B%5D=#{rich_issue.id}")
      expect(link).to include("ids%5B%5D=#{other.id}")
      expect(link).to include('back_url=%2Fissues')
      expect(link).to include('class="icon icon-download cma-export-link"')
      expect(link).not_to include('data-remote')
      expect(link).to include("#{I18n.t(:button_export)} (JSON)")
      expect(link).to include('#icon--download') if cma_sprite_icons?
    end

    it 'is not offered without export_issues_json' do
      user = cma_user
      cma_member(user, project, [:view_issues])

      expect(menu(user, [rich_issue.id])).to be_nil
    end

    it 'is not offered when one selected issue is in a project without the permission' do
      user = exporter([:view_issues])
      cma_member(user, private_project, [:view_issues])

      expect(menu(user, [rich_issue.id, invisible_issue.id])).to be_nil
    end

    it 'is not offered while switched off, which is the default' do
      user = exporter([:view_issues])
      Setting.plugin_redmine_context_menu_actions = {}

      expect(menu(user, [rich_issue.id])).to be_nil
    end

    it 'is offered over the limit too; the request then says why there is no file' do
      cma_settings('export_json_limit' => '1')
      other = cma_issue(project: project)

      expect(menu(exporter([:view_issues]), [rich_issue.id, other.id])).not_to be_nil
    end
  end

  describe 'the permission' do
    let(:permission) { Redmine::AccessControl.permission(:export_issues_json) }

    it 'belongs to the issue tracking module, is read only and grants the export only' do
      expect(permission.project_module).to eq(:issue_tracking)
      expect(permission.read?).to be(true)
      expect(permission.actions).to eq(['context_menu_actions_export/issues'])
    end

    it 'is granted to no role by default' do
      expect(Role.all.select { |role| role.permissions.include?(:export_issues_json) }).to eq([])
    end
  end
end
