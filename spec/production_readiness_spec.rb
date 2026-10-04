# frozen_string_literal: true

require_relative 'spec_helper'

# The ways the plugin reaches a user in production: every page that shows the
# issue context menu, the menu itself as each of those pages asks for it, and
# the parts of Redmine it must leave alone.
RSpec.describe 'production paths' do
  let(:session) { cma_login_admin }

  # Production eager loads every file; a file whose constant does not match its
  # name fails there and nowhere else.
  it 'names every constant the way Zeitwerk expects' do
    expect(RedmineContextMenuActions::Hooks.ancestors).to include(Redmine::Hook::ViewListener)
    expect(RedmineContextMenuActions::IssueUpdater).to be_a(Class)
    expect(RedmineContextMenuActions::Predicates).to be_a(Module)
    expect(RedmineContextMenuActions::Icons).to be_a(Module)
    expect(RedmineContextMenuActions::Coexistence).to be_a(Module)
    expect(ContextMenuActionsController.ancestors).to include(ApplicationController)
    expect(ContextMenuActionsHelper).to be_a(Module)
  end

  it 'registers its hooks once' do
    listeners = Redmine::Hook.listeners.grep(RedmineContextMenuActions::Hooks)
    expect(listeners.size).to eq(1)
  end

  {
    'the issue list' => '/projects/ecookbook/issues',
    'the cross-project issue list' => '/issues',
    'the Gantt chart' => '/projects/ecookbook/issues/gantt',
    'the calendar' => '/projects/ecookbook/issues/calendar',
    'My page' => '/my/page',
    'an issue with subtasks and relations' => '/issues/1',
    'the roadmap' => '/projects/ecookbook/roadmap',
    'a version' => '/versions/2'
  }.each do |name, path|
    it "renders #{name} with the plugin's assets" do
      session.get path
      expect(session.response.status).to eq(200)
      expect(session.response.body).to match(/context_menu_actions[^"]*\.js/)
    end
  end

  # The context menu also opens on these pages; core works out where it came from
  # with back_url, and the actions must be there whatever it is.
  ['/projects/ecookbook/issues/gantt', '/projects/ecookbook/issues/calendar', '/my/page', '/issues/1',
   '/projects/ecookbook/roadmap'].each do |back|
    it "offers the actions in a context menu opened from #{back}" do
      session.get '/issues/context_menu', :params => {:ids => [2], :back_url => back}, :xhr => true
      expect(session.response.status).to eq(200)
      expect(session.response.body).to include('/context_menu_actions/notes/new')
      expect(session.response.body).to include('/context_menu_actions/dates/edit')
    end
  end

  it 'leaves the REST API alone' do
    Setting.rest_api_enabled = '1'
    session.get '/issues.json', :params => {:key => User.find(1).api_key}

    expect(session.response.status).to eq(200)
    expect(session.response.body).not_to include('context_menu_actions')
  end

  it 'leaves the exports alone' do
    session.get '/projects/ecookbook/issues.csv'
    expect(session.response.status).to eq(200)
    expect(session.response.body).not_to include('context_menu_actions')
  end

  it 'answers a JavaScript request without layout, an HTML request with a redirect' do
    session.get '/context_menu_actions/notes/new', :params => {:ids => [1]}, :xhr => true
    expect(session.response.media_type).to eq('text/javascript')
    expect(session.response.body).not_to include('<html')

    session.get '/context_menu_actions/dates/edit', :params => {:ids => [1, 2]}
    expect(session.response.status).to eq(302)
    expect(session.response.location).to include('/issues/bulk_edit')
  end
end
