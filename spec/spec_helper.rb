# frozen_string_literal: true

# Boots a real Redmine so that every action is exercised against a real database,
# with Redmine's own fixtures, permissions, journals and mailer. The plugin is a
# thin layer over core behaviour; mocking that behaviour away would test nothing.
#
# Run from the Redmine root:
#   RAILS_ENV=test bundle exec rspec plugins/redmine_context_menu_actions/spec

ENV['RAILS_ENV'] ||= 'test'

REDMINE_ROOT = File.expand_path('../../..', __dir__)
require File.join(REDMINE_ROOT, 'config', 'environment')

require 'rspec'
# Not autoloaded on Rails 6.1 (Redmine 5.x), which only pulls it in from its own
# test helper.
require 'active_record/fixtures'

FIXTURES_PATH = File.join(REDMINE_ROOT, 'test', 'fixtures')
FIXTURE_NAMES = Dir[File.join(FIXTURES_PATH, '*.yml')].map { |f| File.basename(f, '.yml') }.sort.freeze
CMA_PLUGIN_ROOT = File.expand_path('..', __dir__)

module CmaSpecHelpers
  def cma_plugin_file(path)
    File.join(CMA_PLUGIN_ROOT, path)
  end

  def cma_settings(overrides)
    Setting.plugin_redmine_context_menu_actions =
      RedmineContextMenuActions::DEFAULT_SETTINGS.merge(Setting.plugin_redmine_context_menu_actions.to_h).merge(overrides)
  end

  # A Redmine checkout from 6.0 on renders icons through sprite_icon; 5.1 has
  # CSS icon classes only.
  def cma_sprite_icons?
    ApplicationHelper.method_defined?(:sprite_icon)
  end

  def cma_redmine_version
    Gem::Version.new(Redmine::VERSION.to_s.split('.').first(2).join('.'))
  end

  # A role with exactly the permissions given, attached to the user on the
  # project, so a spec states every permission it relies on.
  def cma_member(user, project, permissions, issues_visibility: 'all')
    role = Role.new(:name => "cma role #{SecureRandom.hex(4)}", :issues_visibility => issues_visibility)
    role.permissions = permissions
    role.save!
    Member.where(:user_id => user.id, :project_id => project.id).destroy_all
    Member.create!(:principal => user, :project => project, :roles => [role])
    user.reload
    role
  end

  # A user who is not a member anywhere, so only the roles a spec gives apply.
  def cma_user(login = "cma#{SecureRandom.hex(3)}")
    user = User.new(:firstname => 'Context', :lastname => 'Menu', :mail => "#{login}@example.net")
    user.login = login
    user.password = 'cmaPassword1!'
    user.password_confirmation = 'cmaPassword1!'
    user.save!
    user
  end

  def cma_issue(project: Project.find(1), tracker: nil, author: User.find(1), subject: 'cma issue', **attrs)
    issue = Issue.new(
      :project => project,
      :tracker => tracker || project.trackers.first,
      :status => IssueStatus.where(:is_closed => false).sorted.first,
      :author => author,
      :subject => subject,
      :priority => IssuePriority.active.first
    )
    attrs.each { |key, value| issue.send(:"#{key}=", value) }
    issue.save!
    issue.reload
  end

  def cma_session
    ActionDispatch::Integration::Session.new(Rails.application)
  end

  def cma_login(session, login, password)
    session.post '/login', :params => {:username => login, :password => password}
    expect(session.response.status).to eq(302)
    session
  end

  def cma_login_admin
    cma_login(cma_session, 'admin', 'admin')
  end

  # The JSON a submit response hands to RedmineContextMenuActions.saved,
  # decoded, so assertions see the HTML the browser will see.
  def cma_saved_payload(body)
    json = body[/RedmineContextMenuActions\.saved\((.*)\);\s*\z/m, 1]
    raise "no saved() call in #{body[0, 200]}" unless json

    JSON.parse(json)
  end

  # The SQL statements a block runs, schema, transaction and cached lookups
  # excluded.
  def cma_queries(&block)
    queries = []
    collector = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      next if payload[:sql].to_s.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      queries << payload[:sql].to_s
    end
    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record', &block)
    queries
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.include CmaSpecHelpers

  config.before(:suite) do
    ActiveRecord::FixtureSet.create_fixtures(FIXTURES_PATH, FIXTURE_NAMES)
  end

  # Not joinable, so the save inside an example runs in a savepoint of its own and
  # its after_commit callbacks fire, as in production. Journals send their mail
  # from after_create_commit; with a joinable wrapper no notification would ever
  # leave and the mail examples would assert on nothing.
  config.around(:each) do |example|
    ActiveRecord::Base.transaction(:joinable => false) do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  config.before(:each) do
    User.current = nil
    I18n.locale = :en
    Setting.clear_cache
    ActionMailer::Base.deliveries.clear
  end

  config.after(:each) do
    User.current = nil
  end
end
