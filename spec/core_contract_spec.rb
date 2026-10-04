# frozen_string_literal: true

require_relative 'spec_helper'

# One example per assumption the plugin makes about Redmine, so an upgrade that
# moves any of them fails here, by name, instead of breaking a menu or a dialog
# somewhere else. COMPATIBILITY.md is the prose version of this file.
RSpec.describe 'what the plugin assumes about Redmine' do
  def core_source(*candidates)
    path = candidates.map { |c| Rails.root.join(c) }.find(&:exist?)
    raise "none of #{candidates.join(', ')} exists" unless path

    File.read(path)
  end

  # Redmine moved its JavaScript twice: public/ on 5.1, app/assets on 6.0, and the
  # non-module code into application-legacy.js from 6.1 on.
  def core_application_js
    core_source('app/assets/javascripts/application-legacy.js',
                'app/assets/javascripts/application.js',
                'public/javascripts/application.js')
  end

  def core_context_menu_js
    core_source('app/assets/javascripts/context_menu.js', 'public/javascripts/context_menu.js')
  end

  describe 'the issue context menu view' do
    let(:view) { core_source('app/views/context_menus/issues.html.erb') }

    it 'calls view_issues_context_menu_start first and view_issues_context_menu_end last' do
      lines = view.lines.map(&:strip).reject(&:empty?)

      expect(lines[1]).to eq('<%= call_hook(:view_issues_context_menu_start, {:issues => @issues, :can => @can, :back => @back }) %>')
      expect(lines[-2]).to eq('<%= call_hook(:view_issues_context_menu_end, {:issues => @issues, :can => @can, :back => @back }) %>')
    end

    it 'renders its items with sprite icons from 6.0 on, CSS icons before' do
      if cma_sprite_icons?
        expect(view).to include("context_menu_link sprite_icon('edit', l(:button_edit))")
      else
        expect(view).to include("context_menu_link l(:button_edit), edit_issue_path(@issue)")
      end
      expect(view).to include(":class => 'icon icon-edit'")
    end
  end

  describe 'the issue list page' do
    it 'calls view_issues_index_bottom with the issues of the page and the query' do
      expect(core_source('app/views/issues/index.html.erb'))
        .to include('<%= call_hook(:view_issues_index_bottom, { :issues => @issues, :project => @project, :query => @query }) %>')
    end

    it 'loads the issues of a page with their project, for notes_addable? without extra queries' do
      query = IssueQuery.new(:name => '_')
      query.filters = {}
      expect(query.issues(:limit => 2).first.association(:project)).to be_loaded
    end
  end

  describe 'the layout' do
    let(:layout) { core_source('app/views/layouts/base.html.erb') }

    it 'has the ajax-modal container the dialogs open in' do
      expect(layout).to include('<div id="ajax-modal" style="display:none;"></div>')
    end

    it 'calls view_layouts_base_html_head before it yields the header tags' do
      head_hook = layout.index('call_hook :view_layouts_base_html_head')
      header_tags = layout.index('yield :header_tags')

      expect(head_hook).not_to be_nil
      expect(header_tags).not_to be_nil
      expect(head_hook).to be < header_tags
    end

    it 'sets up inline autocomplete data sources on every page' do
      expect(layout).to include('heads_for_auto_complete(@project)')
    end
  end

  describe 'the core JavaScript the dialogs rely on' do
    it 'defines showModal and hideModal' do
      expect(core_application_js).to include('function showModal(id, width, title)')
      expect(core_application_js).to include('function hideModal(el)')
    end

    it 'attaches inline autocomplete on focus of any data-auto-complete field' do
      expect(core_application_js).to match(/\$\(document\)\.on\('focus', '\[data-auto-complete=true\]'/)
    end

    # Core only listens inside #content. The dialog is attached to #content while
    # it is open, so core's handler applies; the plugin binds the Clear checkbox
    # as well, for a page whose layout has no #content.
    it 'listens for data-disables only inside #content' do
      expect(core_application_js).to include("$('#content').on('change', 'input[data-disables], input[data-enables], input[data-shows]', toggleDisabledOnChange);")
    end

    # The dialogs leave Ctrl+Enter and Cmd+Enter to core, which clicks the first
    # submit button of a remote form, so a disabled button stays disabled.
    it 'submits a remote form on Ctrl+Enter in a textarea, by clicking its submit button' do
      expect(core_application_js).to include("$(document).on('keydown', 'form textarea', function(e) {")
      expect(core_application_js).to include("targetForm.find('input[type=submit]').first().click();")
    end

    it 'keeps the selection while a modal is open' do
      expect(core_context_menu_js).to include("$('#ajax-modal').is(':visible')")
    end

    it 'hides the context menu with contextMenuHide' do
      expect(core_context_menu_js).to include('function contextMenuHide()')
    end

    # Why the dialog is attached to #content while it is open.
    it 'styles the wiki toolbar tabs inside #content only' do
      css = core_source('app/assets/stylesheets/jstoolbar.css', 'public/stylesheets/jstoolbar.css')
      expect(css).to include('#content .jstTabs.tabs')
      expect(core_source('app/assets/stylesheets/application.css', 'public/stylesheets/application.css')).to include('#content .tabs ul')
    end

    it 'leaves a click on a link in the menu to the link' do
      expect(core_context_menu_js).to include("if (target.is('a') || target.is('img')) { return; }")
    end

    # The dialog tells Esc from the close button and Cancel by the event that
    # closes it: jQuery UI passes the keydown event for Esc, core's hideModal
    # (Cancel) passes none.
    it 'closes a dialog on Esc with the key event, and from hideModal without one' do
      jquery = core_source(*%w[app/assets/javascripts/jquery-3.7.1-ui-1.13.3.js public/javascripts/jquery-3.6.1-ui-1.13.2-ujs-6.1.7.6.js])
      escape = 't.keyCode&&t.keyCode===V.ui.keyCode.ESCAPE'
      expect(jquery).to include("#{escape}?(t.preventDefault(),this.close(t))").or include("#{escape})return t.preventDefault(),void this.close(t)")
      expect(core_application_js[/^function hideModal\(el\) \{.*?^\}/m]).to include('modal.dialog("close");')
    end

    # The other reason the dialog is attached to #content.
    it 'delegates the preview tab of the wiki toolbar inside #content only' do
      expect(core_application_js).to include("$('#content').on('click', 'div.jstTabs a.tab-preview'")
    end

    # The plugin moves the dialog and re-applies the position option it has;
    # core sets none, so jQuery UI's own placement (kept on screen) stays.
    it 'opens a modal without a position of its own' do
      show_modal = core_application_js[/^function showModal\(id, width, title\) \{.*?^\}/m]
      expect(show_modal).to be_present
      expect(show_modal).not_to include('position')
    end

    # A Last notes row inserted into a collapsed group starts hidden, because
    # core flips every row of a group one by one.
    it 'collapses and expands a group by toggling each of its rows' do
      toggle = core_application_js[/^function toggleRowGroup\(el\) \{.*?^\}/m]
      expect(toggle).to include("n.toggle();")
    end

    # The plugin CSS lets the buttons wrap inside its dialogs, where core's
    # one-line layout (a 42px item in a clipped bar) would hide some of them.
    it 'builds the wiki toolbar as a tab list item holding the buttons, in a clipped bar' do
      toolbar = core_source('app/assets/javascripts/jstoolbar/jstoolbar.js', 'public/javascripts/jstoolbar/jstoolbar.js')
      expect(toolbar).to include("this.tabsBlock.className = 'jstTabs tabs';")
      expect(toolbar).to include("elementsTab.classList = 'tab-elements';")
      expect(toolbar).to include("this.toolbar.className = 'jstElements';")
      css = core_source('app/assets/stylesheets/jstoolbar.css', 'public/stylesheets/jstoolbar.css')
      expect(css).to match(/#content \.jstTabs\.tabs li \{\s*(height|block-size): 42px;/)
      application = core_source('app/assets/stylesheets/application.css', 'public/stylesheets/application.css')
      expect(application).to match(/#content \.tabs \{[^}]*overflow: ?hidden;/)
    end

    # Why the plugin CSS lifts them while a dialog is open.
    it 'appends the table and code language pickers of the wiki toolbar to body' do
      toolbar = core_source('app/assets/javascripts/jstoolbar/jstoolbar.js', 'public/javascripts/jstoolbar/jstoolbar.js')
      expect(toolbar).to include(%(var menu = $("<table class='table-generator'></table>");))
      expect(toolbar).to include('menu.menu().width(150)')
      expect(toolbar.scan('$("body").append(menu);').size).to eq(2)
    end
  end

  describe 'the helpers the plugin calls' do
    let(:view) do
      view = ActionView::Base.empty
      view.extend(ApplicationHelper)
      view
    end

    it 'marks a page that has a context menu' do
      expect(ApplicationHelper.instance_method(:context_menu).source_location).not_to be_nil
      expect(core_source('app/helpers/application_helper.rb')).to include('@context_menu_included = true')
    end

    it 'defines datepickerOptions with the calendar headers, for the date picker fallback' do
      expect(core_source('app/helpers/application_helper.rb')).to include("var datepickerOptions={dateFormat: 'yy-mm-dd'")
      expect(core_application_js).to include('datepickerFallback')
    end

    it 'toggles a collapsible fieldset with toggleFieldset' do
      expect(core_application_js).to include('function toggleFieldset(el)')
    end

    it 'ships calendar.png, which 5.1 shows for Dates' do
      path = %w[public/images/calendar.png app/assets/images/calendar.png].map { |p| Rails.root.join(p) }.find(&:exist?)
      expect(path).not_to be_nil
    end

    it 'has sprite_icon from 6.0 on, and a comment icon in the core sprite' do
      if cma_redmine_version >= Gem::Version.new('6.0')
        expect(ApplicationHelper.method_defined?(:sprite_icon)).to be(true)
        names = YAML.load_file(Rails.root.join('config', 'icon_source.yml')).map { |icon| icon['name'] }
        expect(names).to include('comment')
        expect(core_source('app/assets/images/icons.svg')).to include('id="icon--comment"')
        # No calendar in core, which is why the plugin ships its own sprite.
        expect(names).not_to include('calendar')
      else
        # Core's own helpers, not ApplicationHelper: another plugin can add one.
        defined_by_core = Dir[Rails.root.join('app', 'helpers', '*.rb')].any? { |f| File.read(f).include?('def sprite_icon') }
        expect(defined_by_core).to be(false)
      end
    end
  end

  describe 'the issue list markup the dialogs update' do
    let(:list) { core_source('app/views/issues/_list.html.erb') }

    it 'gives each issue row its id and the context menu class' do
      expect(list).to include('<tr id="issue-<%= issue.id %>" class="hascontextmenu <%= cycle(\'odd\', \'even\') %>')
    end

    # The block rows carry no issue id: they are found as the rows after it.
    it 'renders block columns as rows after the issue row, with the column css class' do
      expect(list).to include('<tr class="<%= current_cycle %>">')
      expect(list).to include('<td colspan="<%= query.inline_columns.size + 2 %>" class="<%= column.css_classes %> block_column">')
      expect(list).to include('<% if query.block_columns.count > 1 %>')
      expect(list).to include('<span><%= column.caption %></span>')
    end

    it 'posts the list columns with the context menu request, as c[]' do
      expect(list).to include('<%= query_columns_hidden_tags(query) %>')
      expect(core_source('app/helpers/queries_helper.rb')).to include('hidden_field_tag("c[]", column.name, :id => nil)')
    end

    it 'renders the Last notes column as a wiki div through textilizable' do
      expect(core_source('app/helpers/queries_helper.rb'))
        .to include(%(item.last_notes.present? ? content_tag('div', textilizable(item, :last_notes), :class => "wiki") : ''))
      column = IssueQuery.available_columns.detect { |c| c.name == :last_notes }
      expect(column).not_to be_nil
      expect(column.inline?).to be(false)
      expect(column.css_classes).to eq(:last_notes)
      expect(column.caption).to eq(I18n.t(:label_last_notes))
    end

    it 'loads the last visible note of many issues at once, private notes by core rules' do
      expect(Issue).to respond_to(:load_visible_last_notes)
      expect(Issue.method(:load_visible_last_notes).arity).to eq(-2)
      condition = Journal.visible_notes_condition(User.find(2), :skip_pre_condition => true)
      # Own private notes stay visible to their author.
      expect(condition).to include("#{Journal.table_name}.user_id")
    end
  end

  describe 'core bulk edit, the behaviour the endpoint mirrors' do
    let(:controller) { core_source('app/controllers/issues_controller.rb') }

    it 'journals, assigns safe attributes and calls the bulk edit hook before each save' do
      expect(controller).to include('journal = issue.init_journal(User.current, params[:notes])')
      expect(controller).to include('issue.safe_attributes = attributes')
      expect(controller).to include('call_hook(:controller_issues_bulk_edit_before_save, {:params => params, :issue => issue})')
    end

    it 'saves issue by issue, so one failure does not undo the others' do
      expect(controller).to include('unsaved_issues << orig_issue')
    end

    # A save earlier in the loop can change a later issue (a rescheduled
    # follower); core reloads each one first, and so does the plugin.
    it 'reloads each issue before it changes it' do
      expect(controller).to match(/@issues\.each do \|orig_issue\|\n\s*orig_issue\.reload/)
    end

    it 'authorizes bulk_update with edit_issues and edit_own_issues only' do
      allowed = Redmine::AccessControl.permissions.select { |p| p.actions.include?('issues/bulk_update') }.map(&:name)
      expect(allowed).to include(:edit_issues, :edit_own_issues)
      expect(allowed).not_to include(:add_issue_notes)
    end

    it 'loads issues with find_issues: 404 when none, Unauthorized when one is not visible' do
      source = core_source('app/controllers/application_controller.rb')
      expect(source).to include('raise ActiveRecord::RecordNotFound if @issues.empty?')
      expect(source).to include('raise Unauthorized unless @issues.all?(&:visible?)')
      expect(source).to include('@project = @projects.first if @projects.size == 1')
    end
  end

  # The dialogs ask before typed text is lost exactly when core would.
  describe "core's warning on leaving unsaved text" do
    it 'is on unless the user switched it off, with its core text' do
      expect(UserPreference.new.warn_on_leaving_unsaved).to eq('1')
      helper = core_source('app/helpers/application_helper.rb')
      expect(helper).to include("unless User.current.pref.warn_on_leaving_unsaved == '0'")
      expect(helper).to include('l(:text_warn_on_leaving_unsaved)')
    end
  end

  describe 'the issue safe attributes the actions rely on' do
    let(:issue) { Issue.find(1) }
    let(:user) { User.find(2) }

    it 'gates notes on add_issue_notes and private_notes on set_notes_private' do
      role = Role.find(1)
      role.remove_permission!(:add_issue_notes, :set_notes_private, :edit_issues, :edit_own_issues)
      user.reload
      names = issue.safe_attribute_names(user)
      expect(names).not_to include('notes', 'private_notes')

      role.add_permission!(:add_issue_notes)
      user.reload
      expect(Issue.find(1).safe_attribute_names(user)).to include('notes')
      expect(Issue.find(1).safe_attribute_names(user)).not_to include('private_notes')

      role.add_permission!(:set_notes_private)
      user.reload
      expect(Issue.find(1).safe_attribute_names(user)).to include('private_notes')
    end

    it 'delegates notes and private_notes to the current journal' do
      issue.init_journal(user)
      issue.notes = 'x'
      issue.private_notes = true
      expect(issue.current_journal.notes).to eq('x')
      expect(issue.current_journal.private_notes).to be(true)
    end

    it 'refuses notes on a closed project, even to an administrator' do
      issue.project.update_column(:status, Project::STATUS_CLOSED)
      expect(Issue.find(1).notes_addable?(User.find(1))).to be(false)
    end

    it 'drops start and due date from the safe attributes of a parent with derived dates' do
      previous = Setting.parent_issue_dates
      Setting.parent_issue_dates = 'derived'
      child = cma_issue(project: Project.find(1))
      child.update!(:parent_issue_id => 1)

      expect(Issue.find(1).safe_attribute_names(User.find(1))).not_to include('start_date', 'due_date')
    ensure
      Setting.parent_issue_dates = previous
    end

    it 'drops a date the workflow makes read-only' do
      WorkflowPermission.create!(:role_id => 1, :tracker_id => issue.tracker_id, :old_status_id => issue.status_id,
                                 :field_name => 'start_date', :rule => 'readonly')
      expect(Issue.find(1).safe_attribute_names(user)).not_to include('start_date')
      expect(Issue.find(1).safe_attribute_names(user)).to include('due_date')
    end

    it 'treats an empty date as no change and "none" as a cleared one in core bulk edit' do
      source = core_source('app/controllers/application_controller.rb')
      expect(source).to match(/def parse_params_for_bulk_update\(params\)\n\s*attributes = \(params \|\| \{\}\)\.reject \{\|k, v\| v\.blank\?\}/)
      expect(source).to include("attributes.each_key {|k| attributes[k] = '' if attributes[k] == 'none'}")
    end

    it 'uses optimistic locking on issues' do
      expect(Issue.locking_enabled?).to be_truthy
      expect(Issue.locking_column).to eq('lock_version')
    end
  end

  describe 'the routes' do
    # 7.0 moved the context menu to ContextMenus::IssuesController; the view and
    # its hooks stayed where they were.
    it 'serves the issue context menu at /issues/context_menu' do
      route = Rails.application.routes.recognize_path('/issues/context_menu')
      expect([%w[context_menus issues], %w[context_menus/issues index]]).to include([route[:controller], route[:action]])
    end

    it 'has the preview routes the wiki toolbar posts to' do
      helpers = Rails.application.routes.url_helpers
      expect(helpers.preview_issue_path(:project_id => 1, :issue_id => 1)).to eq('/issues/preview?issue_id=1&project_id=1')
      expect(helpers.preview_text_path).to eq('/preview/text')
    end

    it 'has the mention autocomplete route' do
      expect(Rails.application.routes.url_helpers.watchers_autocomplete_for_mention_path(:q => '')).to start_with('/watchers/autocomplete_for_mention')
    end
  end
end
