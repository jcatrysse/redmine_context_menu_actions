# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'Dates' do
  let(:project) { Project.find(1) }
  let(:session) { cma_session }
  let(:user) { cma_user }
  let(:editor) { [:view_issues, :edit_issues] }

  def login_with(permissions)
    cma_member(user, project, permissions)
    cma_login(session, user.login, 'cmaPassword1!')
  end

  def menu(ids)
    session.get '/issues/context_menu', :params => {:ids => ids}, :xhr => true
    expect(session.response.status).to eq(200)
    session.response.body
  end

  def dates_link(body)
    body[%r{<a [^>]*href="/context_menu_actions/dates/edit[^"]*"[^>]*>.*?</a>}m]
  end

  def open_dialog(ids)
    session.get '/context_menu_actions/dates/edit', :params => {:ids => ids}, :xhr => true
    session.response
  end

  def dialog_html
    raw = session.response.body[/^\s*html: '((?:[^'\\]|\\.)*)'/m, 1]
    raise "no html option in #{session.response.body[0, 300]}" unless raw

    raw.gsub(/\\(.)/m) { Regexp.last_match(1) == 'n' ? "\n" : Regexp.last_match(1) }
  end

  def update(ids, issue: {}, notes: nil, extra: {})
    params = {:ids => ids, :issue => issue}.merge(extra)
    params[:notes] = notes if notes
    session.patch '/context_menu_actions/dates', :params => params, :xhr => true
    session.response
  end

  def payload
    cma_saved_payload(session.response.body)
  end

  def role
    Member.find_by(:user_id => user.id, :project_id => project.id).roles.first
  end

  describe 'the menu item' do
    let(:issue) { cma_issue(project: project) }

    it 'is offered with edit permission, as a remote link with a calendar icon' do
      login_with(editor)
      link = dates_link(menu([issue.id]))

      expect(link).not_to be_nil
      expect(link).to include('data-remote="true"')
      expect(link).to include('class="icon icon-calendar cma-menu-link cma-open"')
      expect(link).to include(I18n.t(:label_cma_dates))
    end

    # Old defect: no icon on Redmine 6, where core items use sprite_icon.
    it 'draws the calendar from the plugin sprite from 6.0 on, core calendar.png on 5.1' do
      login_with(editor)
      link = dates_link(menu([issue.id]))

      if cma_sprite_icons?
        expect(link).to match(%r{<svg class="s18 icon-svg"[^>]*><use href="[^"]*plugin_assets/redmine_context_menu_actions/icons[^"]*\.svg#icon--calendar"})
      else
        expect(link).to match(%r{style="background-image: url\(/images/calendar\.png(\?\d+)?\);"})
      end
    end

    # Old defect: the modal markup sat hidden inside the menu <ul>.
    it 'puts no form or hidden dialog inside the context menu' do
      login_with(editor)
      body = menu([issue.id])

      expect(body).not_to include('<form')
      expect(body).not_to include('update-dates-modal')
      expect(body).not_to include('display:none')
    end

    it 'is not offered without edit permission' do
      login_with([:view_issues, :add_issue_notes])
      expect(dates_link(menu([issue.id]))).to be_nil
    end

    it 'is not offered on a parent whose dates derive from its subtasks' do
      with_settings_parent_dates('derived') do
        login_with(editor + [:manage_subtasks])
        child = cma_issue(project: project)
        child.update!(:parent_issue_id => issue.id)

        expect(dates_link(menu([issue.id]))).to be_nil
      end
    end

    it 'is not offered when the workflow makes both dates read-only' do
      login_with(editor)
      %w[start_date due_date].each do |field|
        WorkflowPermission.create!(:role_id => role.id, :tracker_id => issue.tracker_id, :old_status_id => issue.status_id,
                                   :field_name => field, :rule => 'readonly')
      end

      expect(dates_link(menu([issue.id]))).to be_nil
    end

    it 'is not offered when switched off' do
      login_with(editor)
      cma_settings('enable_dates' => '0')
      expect(dates_link(menu([issue.id]))).to be_nil
    end

    # Next to Add a note, both where the position setting says.
    it 'sits right below Add a note, above Edit by default and at the end when set to bottom' do
      login_with(editor + [:add_issue_notes])
      body = menu([issue.id])
      edit = body.index("/issues/#{issue.id}/edit")
      expect(body.index('/context_menu_actions/notes/new')).to be < body.index('/context_menu_actions/dates/edit')
      expect(body.index('/context_menu_actions/dates/edit')).to be < edit
      expect(body[body.index('/context_menu_actions/notes/new')...body.index('/context_menu_actions/dates/edit')].scan('<li').size).to eq(1)

      cma_settings('menu_position' => 'bottom')
      body = menu([issue.id])
      edit = body.index("/issues/#{issue.id}/edit")
      expect(body.index('/context_menu_actions/notes/new')).to be > edit
      expect(body.index('/context_menu_actions/dates/edit')).to be > body.index('/context_menu_actions/notes/new')
    end

    it 'follows the position setting when Add a note is off' do
      login_with(editor)
      cma_settings('enable_notes' => '0', 'menu_position' => 'bottom')
      body = menu([issue.id])
      expect(body.index('/context_menu_actions/dates/edit')).to be > body.index("/issues/#{issue.id}/edit")

      cma_settings('enable_notes' => '0', 'menu_position' => 'top')
      body = menu([issue.id])
      expect(body.index('/context_menu_actions/dates/edit')).to be < body.index("/issues/#{issue.id}/edit")
    end
  end

  describe 'the dialog' do
    # Old defect: fields rendered with :id => nil, so the labels, the date picker
    # and the Clear checkbox all targeted nothing.
    it 'gives every field an id its label and Clear checkbox point to' do
      login_with(editor)
      issue = cma_issue(project: project)
      expect(open_dialog([issue.id]).status).to eq(200)
      html = dialog_html

      %w[start_date due_date].each do |field|
        expect(html).to match(/<input[^>]*type="date"[^>]*id="cma_#{field}"/)
        expect(html).to include(%(<label for="cma_#{field}">#{I18n.t(:"field_#{field}")}</label>))
        clear = html[/<input[^>]*id="cma_#{field}_clear"[^>]*>/]
        expect(clear).to include(%(data-disables="#cma_#{field}"))
        expect(clear).to include('value="none"')
      end
      ids = html.scan(/\bid="([^"]+)"/).flatten
      expect(ids.uniq.size).to eq(ids.size)
    end

    it 'prefills the values of one issue' do
      login_with(editor)
      issue = cma_issue(project: project, start_date: Date.new(2030, 1, 2), due_date: Date.new(2030, 1, 9))
      open_dialog([issue.id])

      expect(dialog_html).to match(/id="cma_start_date"[^>]*value="2030-01-02"|value="2030-01-02"[^>]*id="cma_start_date"/)
      expect(dialog_html).not_to include(I18n.t(:label_cma_mixed_values))
    end

    it 'prefills a value several issues share and marks the ones that differ' do
      login_with(editor)
      a = cma_issue(project: project, start_date: Date.new(2030, 1, 2), due_date: Date.new(2030, 2, 1))
      b = cma_issue(project: project, start_date: Date.new(2030, 1, 2), due_date: Date.new(2030, 3, 1))
      open_dialog([a.id, b.id])
      html = dialog_html

      expect(html[/<input[^>]*id="cma_start_date"[^>]*>/]).to include('value="2030-01-02"')
      expect(html[/<input[^>]*id="cma_due_date"[^>]*>/]).not_to include('value="20')
      expect(html.scan(I18n.t(:label_cma_mixed_values)).size).to eq(1)
    end

    it 'offers only the date the workflow leaves editable' do
      login_with(editor)
      issue = cma_issue(project: project)
      WorkflowPermission.create!(:role_id => role.id, :tracker_id => issue.tracker_id, :old_status_id => issue.status_id,
                                 :field_name => 'start_date', :rule => 'readonly')
      open_dialog([issue.id])

      expect(dialog_html).not_to include('id="cma_start_date"')
      expect(dialog_html).to include('id="cma_due_date"')
    end

    it 'offers the optional note only with add_issue_notes' do
      login_with(editor)
      issue = cma_issue(project: project)
      open_dialog([issue.id])
      expect(dialog_html).not_to include('cma_dates_notes')

      role.add_permission!(:add_issue_notes)
      open_dialog([issue.id])
      expect(dialog_html).to include('id="cma_dates_notes"')
      expect(dialog_html).to include('class="collapsible collapsed cma-dates-notes"')
    end

    it 'carries core message for a due date before the start date' do
      login_with(editor)
      issue = cma_issue(project: project)
      open_dialog([issue.id])
      expect(dialog_html).to include(%(data-cma-date-order="#{I18n.t(:field_due_date)} #{I18n.t('activerecord.errors.messages.greater_than_start_date')}"))
    end

    it 'is refused without edit permission' do
      login_with([:view_issues, :add_issue_notes])
      expect(open_dialog([cma_issue(project: project).id]).status).to eq(403)
    end
  end

  describe 'saving' do
    before { login_with(editor) }

    let(:issue) { cma_issue(project: project, start_date: Date.new(2030, 1, 2), due_date: Date.new(2030, 1, 9)) }

    it 'sets both dates and journals the change once' do
      expect { update([issue.id], issue: {:start_date => '2030-02-01', :due_date => '2030-02-10'}) }
        .to change { issue.journals.count }.by(1)
      issue.reload
      expect([issue.start_date, issue.due_date]).to eq([Date.new(2030, 2, 1), Date.new(2030, 2, 10)])
      expect(issue.journals.last.details.map(&:prop_key)).to contain_exactly('start_date', 'due_date')
      expect(payload['notice']).to eq(I18n.t(:notice_successful_update))
    end

    it 'leaves a date alone when its field is empty' do
      update([issue.id], issue: {:start_date => '', :due_date => '2030-01-20'})
      issue.reload
      expect(issue.start_date).to eq(Date.new(2030, 1, 2))
      expect(issue.due_date).to eq(Date.new(2030, 1, 20))
    end

    it 'clears a date with Clear' do
      update([issue.id], issue: {:due_date => 'none'})
      expect(issue.reload.due_date).to be_nil
      expect(issue.start_date).to eq(Date.new(2030, 1, 2))
    end

    it 'adds the optional note to the same journal' do
      role.add_permission!(:add_issue_notes)
      update([issue.id], issue: {:due_date => '2030-01-31'}, notes: 'Supplier is late')

      journal = issue.journals.last
      expect(journal.notes).to eq('Supplier is late')
      expect(journal.details.map(&:prop_key)).to eq(['due_date'])
    end

    # The first answer was lost; the user changed a date and submitted again,
    # with the same note. The note is not added twice, the new date is applied.
    it 'applies the dates of a second submit without adding its note again' do
      role.add_permission!(:add_issue_notes)
      since = {:cma_since => 1.minute.ago.to_i}
      update([issue.id], issue: {:due_date => '2030-01-31'}, notes: 'Supplier is late', extra: since)
      update([issue.id], issue: {:due_date => '2030-02-28'}, notes: 'Supplier is late', extra: since)

      expect(issue.reload.due_date).to eq(Date.new(2030, 2, 28))
      expect(issue.journals.where.not(:notes => [nil, '']).pluck(:notes)).to eq(['Supplier is late'])
      expect(payload['failed']).to eq([])
    end

    it 'refuses the note without add_issue_notes, and the dates with it' do
      update([issue.id], issue: {:due_date => '2030-01-31'}, notes: 'Not allowed')
      expect(issue.reload.due_date).to eq(Date.new(2030, 1, 9))
      expect(payload['errorsHtml']).to include(I18n.t(:notice_not_authorized))
    end

    it 'keeps the dates and reports core error when the start is after the due date' do
      update([issue.id], issue: {:start_date => '2030-03-01', :due_date => '2030-02-01'})

      expect(issue.reload.start_date).to eq(Date.new(2030, 1, 2))
      expect(payload['failed']).to eq([issue.id])
      expect(payload['errorsHtml']).to include("##{issue.id}: #{I18n.t(:field_due_date)} #{I18n.t('activerecord.errors.messages.greater_than_start_date')}")
    end

    it 'reports an invalid date per issue' do
      update([issue.id], issue: {:start_date => '2030-13-45'})
      expect(payload['failed']).to eq([issue.id])
      expect(payload['errorsHtml']).to include(I18n.t('activerecord.errors.messages.not_a_date'))
    end

    it 'changes several issues, each with one journal' do
      other = cma_issue(project: project)
      update([issue.id, other.id], issue: {:due_date => '2030-06-30'})

      expect([issue.reload.due_date, other.reload.due_date]).to eq([Date.new(2030, 6, 30)] * 2)
      expect([issue.journals.count, other.journals.count]).to eq([1, 1])
    end

    it 'saves the valid issues and reports the others' do
      late = cma_issue(project: project, start_date: Date.new(2030, 9, 1))
      update([issue.id, late.id], issue: {:due_date => '2030-06-30'})

      expect(issue.reload.due_date).to eq(Date.new(2030, 6, 30))
      expect(late.reload.due_date).to be_nil
      expect(payload['saved'].map { |s| s['id'] }).to eq([issue.id])
      expect(payload['failed']).to eq([late.id])
    end

    it 'lets core reschedule the issues that follow' do
      following = cma_issue(project: project, start_date: Date.new(2030, 1, 10), due_date: Date.new(2030, 1, 12))
      IssueRelation.create!(:issue_from => issue, :issue_to => following, :relation_type => 'precedes')

      update([issue.id], issue: {:due_date => '2030-01-20'})
      expect(following.reload.start_date).to eq(Date.new(2030, 1, 21))
    end

    it 'refuses a value for a field the workflow makes read-only, and changes nothing' do
      WorkflowPermission.create!(:role_id => role.id, :tracker_id => issue.tracker_id, :old_status_id => issue.status_id,
                                 :field_name => 'start_date', :rule => 'readonly')

      update([issue.id], issue: {:start_date => '2030-05-01', :due_date => '2030-05-09'})
      issue.reload
      expect([issue.start_date, issue.due_date]).to eq([Date.new(2030, 1, 2), Date.new(2030, 1, 9)])
      expect(payload['errorsHtml']).to include(I18n.t(:notice_not_authorized))
    end

    it 'saves nothing and confirms nothing when nothing was asked' do
      expect { update([issue.id], issue: {:start_date => '', :due_date => ''}) }.not_to(change { Journal.count })
      expect(payload['saved']).to eq([])
      expect(payload['failed']).to eq([])
    end
  end

  describe 'refusals' do
    let(:issue) { cma_issue(project: project) }

    it 'refuses a user without edit permission' do
      login_with([:view_issues, :add_issue_notes])
      expect(update([issue.id], issue: {:due_date => '2030-01-01'}).status).to eq(403)
      expect(issue.reload.due_date).to be_nil
    end

    it 'refuses a parent whose dates derive from its subtasks' do
      with_settings_parent_dates('derived') do
        login_with(editor + [:manage_subtasks])
        child = cma_issue(project: project)
        child.update!(:parent_issue_id => issue.id)

        expect(update([issue.id], issue: {:due_date => '2030-01-01'}).status).to eq(403)
      end
    end

    it 'answers 404 when switched off' do
      login_with(editor)
      cma_settings('enable_dates' => '0')
      expect(update([issue.id], issue: {:due_date => '2030-01-01'}).status).to eq(404)
    end
  end

  def with_settings_parent_dates(value)
    previous = Setting.parent_issue_dates
    Setting.parent_issue_dates = value
    yield
  ensure
    Setting.parent_issue_dates = previous
  end
end
