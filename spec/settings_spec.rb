# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'plugin settings' do
  let(:session) { cma_login_admin }

  def settings_page
    session.get '/settings/plugin/redmine_context_menu_actions'
    expect(session.response.status).to eq(200)
    session.response.body
  end

  it 'renders an input for every setting, each with a label' do
    body = settings_page

    RedmineContextMenuActions::DEFAULT_SETTINGS.each_key do |key|
      expect(body).to include(%(name="settings[#{key}]")), key
      expect(body).to include(%(<label for="settings_#{key}">)), key
      expect(body).to match(/<(input|select)[^>]*id="settings_#{key}"/), key
    end
  end

  it 'labels every setting with core words or a translated plugin string' do
    body = settings_page

    expect(body).to include(%(<label for="settings_enable_notes">#{I18n.t(:label_add_note)}</label>))
    expect(body).to include(%(<label for="settings_enable_last_notes_link">#{I18n.t(:label_last_notes)}: #{I18n.t(:label_add_note)}</label>))
    expect(body).to include(%(<label for="settings_enable_dates">#{I18n.t(:label_cma_dates)}</label>))
    expect(body).not_to include('translation missing')
  end

  it 'posts an explicit 0 for every unticked box' do
    body = settings_page
    %w[enable_notes enable_last_notes_link enable_dates].each do |key|
      expect(body).to include(%(<input type="hidden" name="settings[#{key}]" value="0" autocomplete="off" />)), key
    end
  end

  it 'stores 0 when a box is unticked, and the action disappears' do
    session.post '/settings/plugin/redmine_context_menu_actions',
                 :params => {:settings => {'enable_notes' => '0', 'enable_dates' => '1', 'enable_last_notes_link' => '1',
                                           'menu_position' => 'bottom'}}

    expect(Setting.plugin_redmine_context_menu_actions['enable_notes']).to eq('0')
    expect(RedmineContextMenuActions.notes_enabled?).to be(false)
    expect(RedmineContextMenuActions.menu_position).to eq('bottom')
  end

  it 'renders a setting stored as 0 as unticked' do
    cma_settings('enable_dates' => '0')
    checkbox = settings_page[/<input[^>]*id="settings_enable_dates"[^>]*>/]
    expect(checkbox).not_to include('checked')
  end

  it 'falls back to the defaults on the page for keys an older install did not store' do
    Setting.plugin_redmine_context_menu_actions = {'enable_notes' => '1'}
    body = settings_page

    expect(body[/<input[^>]*id="settings_enable_dates"[^>]*>/]).to include('checked')
    expect(body[%r{<select[^>]*id="settings_menu_position".*?</select>}m]).to include('<option selected="selected" value="top">')
  end

  it 'gives no id twice' do
    ids = settings_page[%r{<div class="box tabular settings">.*?</div>\s*<input type="submit"}m].scan(/\bid="([^"]+)"/).flatten
    expect(ids.uniq.size).to eq(ids.size)
  end

  it 'renders in another language' do
    User.find(1).update_columns(:language => 'de')
    body = settings_page

    expect(body).to include(ERB::Util.html_escape(I18n.t(:label_cma_menu_position, :locale => :de)))
    expect(body).not_to include('translation missing')
  ensure
    User.find(1).update_columns(:language => 'en')
  end

  describe 'next to redmine_issue_todo_lists2' do
    let(:fake_dir) { Dir.mktmpdir('redmine_issue_todo_lists2') }

    def install_todo_lists(plugin_version, stored = nil)
      dir = fake_dir
      Redmine::Plugin.register(:redmine_issue_todo_lists2) do
        name 'Issue To-do Lists'
        version plugin_version
        directory dir
        settings :default => {'enable_dates_context_menu' => true}, :partial => 'settings/none'
      end
      Setting.plugin_redmine_issue_todo_lists2 = stored if stored
    end

    after do
      Redmine::Plugin.unregister(:redmine_issue_todo_lists2)
      FileUtils.remove_entry(fake_dir)
    end

    def warning(body)
      body[%r{<div class="flash warning cma-coexistence">.*?</div>}m]
    end

    it 'warns about the double Dates entry before 2.3.0, with Dates on' do
      install_todo_lists('2.2.2')
      text = warning(settings_page)

      expect(text).to include(ERB::Util.html_escape(I18n.t(:text_cma_todo_lists_dates_conflict, :version => '2.2.2', :fixed => '2.3.0')))
    end

    it 'does not warn when its Dates entry is switched off' do
      install_todo_lists('2.2.2', {'show_in_issue_sidebar' => '1'})
      expect(warning(settings_page)).to be_nil
    end

    it 'does not warn from 2.3.0 on' do
      install_todo_lists('2.3.0')
      expect(warning(settings_page)).to be_nil
    end
  end

  it 'does not warn when redmine_issue_todo_lists2 is not installed' do
    expect(settings_page).not_to include('cma-coexistence')
  end
end
