# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'plugin registration' do
  let(:plugin) { Redmine::Plugin.find(:redmine_context_menu_actions) }

  it 'is registered under its directory name' do
    expect(plugin.id).to eq(:redmine_context_menu_actions)
    expect(plugin.directory).to eq(CMA_PLUGIN_ROOT)
  end

  it 'declares the Redmine version it is tested on' do
    expect { plugin.requires_redmine(:version_or_higher => '5.1') }.not_to raise_error
  end

  it 'adds no permission and no project module of its own' do
    own = Redmine::AccessControl.permissions.select { |p| p.project_module.to_s.include?('context_menu') }
    expect(own).to eq([])
    expect(Redmine::AccessControl.available_project_modules.map(&:to_s).grep(/context_menu/)).to eq([])
  end

  it 'ships the defaults the README documents' do
    expect(plugin.settings[:default]).to eq(
      'enable_notes' => true,
      'menu_position' => 'top',
      'enable_last_notes_link' => true,
      'enable_dates' => true
    )
  end

  describe 'reading a setting' do
    it 'falls back to the default for a key the stored settings do not have yet' do
      Setting.plugin_redmine_context_menu_actions = {'enable_dates' => '1'}

      expect(RedmineContextMenuActions.notes_enabled?).to be(true)
      expect(RedmineContextMenuActions.menu_position).to eq('top')
    end

    it 'reads 0, false and blank as off' do
      ['0', 'false', false, ''].each do |value|
        cma_settings('enable_notes' => value)
        expect(RedmineContextMenuActions.notes_enabled?).to be(false), value.inspect
      end
    end

    it 'reads 1 and true as on' do
      ['1', 'true', true].each do |value|
        cma_settings('enable_dates' => value)
        expect(RedmineContextMenuActions.dates_enabled?).to be(true), value.inspect
      end
    end

    it 'offers the Last notes link only while notes are on' do
      cma_settings('enable_notes' => '0', 'enable_last_notes_link' => '1')
      expect(RedmineContextMenuActions.last_notes_link_enabled?).to be(false)

      cma_settings('enable_notes' => '1')
      expect(RedmineContextMenuActions.last_notes_link_enabled?).to be(true)
    end

    it 'falls back to the top for an unknown position' do
      cma_settings('menu_position' => 'sideways')
      expect(RedmineContextMenuActions.menu_position).to eq('top')

      cma_settings('menu_position' => 'bottom')
      expect(RedmineContextMenuActions.menu_position).to eq('bottom')
    end
  end
end
