# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'the issue context menu' do
  let(:project) { Project.find(1) }
  let(:session) { cma_session }
  let(:user) { cma_user }

  def login_with(permissions, projects: [project])
    projects.each { |p| cma_member(user, p, permissions) }
    cma_login(session, user.login, 'cmaPassword1!')
  end

  def menu(ids, extra = {})
    session.get '/issues/context_menu', :params => {:ids => ids}.merge(extra), :xhr => true
    expect(session.response.status).to eq(200)
    session.response.body
  end

  def note_link(body)
    body[%r{<a [^>]*href="/context_menu_actions/notes/new[^"]*"[^>]*>.*?</a>}m]
  end

  describe 'Add a note' do
    let(:issue) { cma_issue(project: project) }

    it 'is offered to a user with add_issue_notes, as a remote link to the dialog' do
      login_with([:view_issues, :add_issue_notes])
      link = note_link(menu([issue.id]))

      expect(link).not_to be_nil
      expect(link).to include('data-remote="true"')
      expect(link).to include("ids%5B%5D=#{issue.id}")
      expect(link).to include('class="icon icon-comment cma-menu-link cma-open"')
      expect(link).to include(I18n.t(:label_add_note))
    end

    it 'draws the comment icon from the sprite from 6.0 on, a CSS icon on 5.1' do
      login_with([:view_issues, :add_issue_notes])
      link = note_link(menu([issue.id]))

      if cma_sprite_icons?
        expect(link).to match(/<svg class="s18 icon-svg"[^>]*>.*#icon--comment/m)
        expect(link).to include('<span class="icon-label">')
      else
        expect(link).not_to include('<svg')
      end
    end

    it 'is not offered without add_issue_notes' do
      login_with([:view_issues, :edit_issues])
      expect(note_link(menu([issue.id]))).to be_nil
    end

    it 'is offered for several issues when every one of them allows notes' do
      login_with([:view_issues, :add_issue_notes])
      other = cma_issue(project: project)

      expect(note_link(menu([issue.id, other.id]))).to include("ids%5B%5D=#{other.id}")
    end

    it 'is not offered when one of the selected issues does not allow notes' do
      other_project = Project.find(2)
      login_with([:view_issues, :add_issue_notes])
      cma_member(user, other_project, [:view_issues])
      other = cma_issue(project: other_project)

      expect(note_link(menu([issue.id, other.id]))).to be_nil
    end

    it 'is not offered on a closed project' do
      login_with([:view_issues, :add_issue_notes])
      issue
      project.update_column(:status, Project::STATUS_CLOSED)

      expect(note_link(menu([issue.id]))).to be_nil
    end

    it 'is not offered when switched off' do
      login_with([:view_issues, :add_issue_notes])
      cma_settings('enable_notes' => '0')

      expect(note_link(menu([issue.id]))).to be_nil
    end

    it 'sits above Edit by default and at the end when set to bottom' do
      login_with([:view_issues, :add_issue_notes, :edit_issues])
      body = menu([issue.id])
      expect(body.index('/context_menu_actions/notes/new')).to be < body.index("/issues/#{issue.id}/edit")

      cma_settings('menu_position' => 'bottom')
      body = menu([issue.id])
      expect(body.index('/context_menu_actions/notes/new')).to be > body.index("/issues/#{issue.id}/edit")
    end

    it 'passes the columns of the list on, so the dialog knows where Last notes is' do
      login_with([:view_issues, :add_issue_notes])
      link = note_link(menu([issue.id], :c => %w[subject last_notes]))

      expect(link).to include('c%5B%5D=subject')
      expect(link).to include('c%5B%5D=last_notes')
    end

    it 'survives a column parameter that is not a list' do
      login_with([:view_issues, :add_issue_notes])
      expect(note_link(menu([issue.id], :c => {'a' => 'b'}))).not_to include('c%5B')
    end
  end
end
