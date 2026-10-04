# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'the assets in the page head' do
  let(:session) { cma_login_admin }

  def head(path)
    session.get path
    expect(session.response.status).to eq(200)
    session.response.body[%r{<head>.*</head>}m]
  end

  it 'loads the plugin script and stylesheet' do
    html = head('/projects/ecookbook/issues')

    expect(html).to match(%r{<script src="[^"]*context_menu_actions[^"]*\.js})
    expect(html).to match(%r{<link rel="stylesheet"[^>]*context_menu_actions[^"]*\.css})
  end

  # A dialog with a notes field can open on any page with a context menu, and
  # core only loads the toolbar where it renders a notes field itself.
  it 'adds core wiki toolbar and date picker setup on a page with a context menu' do
    html = head('/projects/ecookbook/issues')

    expect(html).to include('jstoolbar/jstoolbar') if Setting.text_formatting.present?
    expect(html).to include('var datepickerOptions=')
  end

  it 'leaves them out on a page without a context menu' do
    html = head('/projects/ecookbook')

    expect(html).not_to include('jstoolbar/jstoolbar')
    expect(html).to match(%r{context_menu_actions[^"]*\.js})
  end

  it 'loads nothing when every action is switched off' do
    cma_settings('enable_notes' => '0', 'enable_dates' => '0')
    html = head('/projects/ecookbook/issues')

    expect(html).not_to include('context_menu_actions')
  end

  it 'serves the script and the stylesheet it links' do
    html = head('/projects/ecookbook/issues')
    %w[js css].each do |ext|
      url = html[%r{(?:src|href)="([^"]*context_menu_actions[^"]*\.#{ext}[^"]*)"}, 1]
      expect(url).not_to be_nil
      path = url.sub(%r{\Ahttps?://[^/]+}, '')
      file = Rails.public_path.join(path.delete_prefix('/').split('?').first)
      # Redmine 5.1 copies plugin assets to public/plugin_assets; 6.x serves them
      # through the asset pipeline. Either way the request must find the file.
      session.get path
      expect(session.response.status).to eq(200), "#{path} (#{file})"
    end
  end
end
