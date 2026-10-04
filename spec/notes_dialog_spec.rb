# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'the Add a note dialog' do
  let(:project) { Project.find(1) }
  let(:session) { cma_session }
  let(:user) { cma_user }
  let(:notes_only) { [:view_issues, :add_issue_notes] }

  def login_with(permissions, projects: [project])
    projects.each { |p| cma_member(user, p, permissions) }
    cma_login(session, user.login, 'cmaPassword1!')
  end

  def open_dialog(ids, extra = {})
    session.get '/context_menu_actions/notes/new', :params => {:ids => ids}.merge(extra), :xhr => true
    session.response
  end

  # The value of one option of the openDialog({...}) call, unescaped from
  # escape_javascript.
  def option(name, response = session.response)
    raw = response.body[/^\s*#{name}: '((?:[^'\\]|\\.)*)'/m, 1]
    raise "no #{name} option in #{response.body[0, 300]}" unless raw

    raw.gsub(/\\(.)/m) { Regexp.last_match(1) == 'n' ? "\n" : Regexp.last_match(1) }
  end

  def dialog_html
    option('html')
  end

  describe 'for one issue' do
    let(:issue) { cma_issue(project: project, subject: 'Recipe <b>bold</b> & "quoted"') }

    before { login_with(notes_only) }

    it 'opens through core showModal, with a notes field like core\'s' do
      expect(open_dialog([issue.id]).status).to eq(200)
      expect(session.response.media_type).to eq('text/javascript')
      html = dialog_html

      expect(html).to include(%(<h3 class="title">#{I18n.t(:label_add_note)}</h3>))
      expect(html).to match(/<textarea[^>]*id="cma_notes"[^>]*>/)
      textarea = html[/<textarea[^>]*>/]
      expect(textarea).to include('name="notes"')
      expect(textarea).to include('class="wiki-edit"')
      expect(textarea).to include('data-auto-complete="true"')
      expect(html).to include('<label for="cma_notes" class="hidden-for-sighted">')
      expect(html).to include(%(<input type="hidden" name="ids[]" value="#{issue.id}"))
      expect(html).to include('data-remote="true"')
    end

    it 'names the issue, escaped' do
      open_dialog([issue.id])
      html = dialog_html

      expect(html).to include("##{issue.id}: Recipe &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot;")
      expect(html).not_to include('<b>bold</b>')
    end

    it 'previews in the context of the issue' do
      open_dialog([issue.id])
      expect(option('toolbar')).to include("/issues/preview?issue_id=#{issue.id}&project_id=#{project.identifier}") if Setting.text_formatting.present?
    end

    it 'offers no private checkbox without set_notes_private' do
      open_dialog([issue.id])
      expect(dialog_html).not_to include('cma_private_notes')
    end

    it 'gives no @mention source without add_issue_watchers, as core' do
      open_dialog([issue.id])
      expect(session.response.body).to match(/mentions: null/)
    end

    it 'keeps the columns of the list for the answer' do
      open_dialog([issue.id], :c => %w[subject last_notes])
      expect(dialog_html).to include('<input type="hidden" name="c[]" value="last_notes"')
    end

    it 'carries the messages for a failed request in the user language' do
      open_dialog([issue.id])
      html = dialog_html

      expect(html).to include(%(data-cma-error-401="#{ERB::Util.html_escape(I18n.t(:error_session_expired))}"))
      expect(html).to include(%(data-cma-error-403="#{I18n.t(:notice_not_authorized)}"))
      expect(html).to include(%(data-cma-error-other="#{ERB::Util.html_escape(I18n.t(:text_cma_request_unknown))}"))
      expect(html).to include(%(data-cma-leave="#{I18n.t(:text_warn_on_leaving_unsaved)}"))
    end

    # The x button, Cancel and leaving the page ask first, as core's own
    # warning does, unless the user switched that warning off.
    it 'asks nothing before closing for a user who switched the unsaved text warning off' do
      user.pref.update!(:warn_on_leaving_unsaved => '0')
      open_dialog([issue.id])
      expect(dialog_html).not_to include('data-cma-leave')
    end

    it 'marks when the dialog was opened, so a second submit of the same note is recognised' do
      open_dialog([issue.id])
      since = dialog_html[/name="cma_since" value="(\d+)"/, 1].to_i

      expect(since).to be_within(5).of(Time.now.to_i)
    end

    it 'uses the textarea attributes of this Redmine version' do
      open_dialog([issue.id])
      textarea = dialog_html[/<textarea[^>]*>/]

      if ApplicationHelper.method_defined?(:wiki_textarea_stimulus_attributes)
        expect(textarea).to include('list-autofill')
      elsif ApplicationHelper.method_defined?(:list_autofill_data_attributes)
        expect(textarea).to include('data-controller="list-autofill"')
      else
        expect(textarea).not_to include('data-controller')
      end
    end
  end

  describe 'permissions' do
    let(:issue) { cma_issue(project: project) }

    it 'adds the private checkbox with set_notes_private, with a label' do
      login_with(notes_only + [:set_notes_private])
      open_dialog([issue.id])

      expect(dialog_html).to include('id="cma_private_notes"')
      expect(dialog_html).to include(I18n.t(:field_private_notes))
    end

    it 'sets the @mention source of the issue with add_issue_watchers' do
      login_with(notes_only + [:add_issue_watchers])
      open_dialog([issue.id])

      mentions = session.response.body[/mentions: (.*)$/, 1].gsub('\\/', '/')
      expect(JSON.parse(mentions)).to start_with('/watchers/autocomplete_for_mention?')
      expect(JSON.parse(mentions)).to include("object_id=#{issue.id}")
    end

    it 'refuses a user without add_issue_notes' do
      login_with([:view_issues])
      expect(open_dialog([issue.id]).status).to eq(403)
    end

    it 'answers 404 when switched off' do
      login_with(notes_only)
      cma_settings('enable_notes' => '0')
      expect(open_dialog([issue.id]).status).to eq(404)
    end
  end

  describe 'for several issues' do
    before { login_with(notes_only + [:set_notes_private], projects: [project, Project.find(3)]) }

    let(:issues) { [cma_issue(project: project), cma_issue(project: project), cma_issue(project: Project.find(3))] }

    it 'shows how many issues and lists them, with their project when they differ' do
      open_dialog(issues.map(&:id))
      html = dialog_html

      expect(html).to include("<summary>#{I18n.t(:label_x_issues, :count => 3)}</summary>")
      issues.each do |issue|
        expect(html).to include("##{issue.id}: ")
        expect(html).to include(%(name="ids[]" value="#{issue.id}"))
      end
      expect(html).to include("#{Project.find(3).name} - ")
    end

    it 'previews as plain text, as core bulk edit does' do
      open_dialog(issues.map(&:id))
      expect(option('toolbar')).to include('/preview/text') if Setting.text_formatting.present?
    end

    it 'offers the private checkbox only when every issue allows it' do
      open_dialog(issues.map(&:id))
      expect(dialog_html).to include('id="cma_private_notes"')

      cma_member(user, Project.find(3), notes_only)
      open_dialog(issues.map(&:id))
      expect(dialog_html).not_to include('id="cma_private_notes"')
    end
  end
end
