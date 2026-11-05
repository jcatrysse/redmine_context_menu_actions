# frozen_string_literal: true

# Exports the selected issues as one JSON file. Each issue is rendered by core's
# own API view, issues/show.api.rsb, with the instance variables
# IssuesController#show sets, as the current user: an entry is exactly what
# GET /issues/:id.json?include=... answers that user, and every rule core and
# other plugins apply to that response (private notes, journal details of hidden
# fields, custom field visibility, hidden core fields) applies here too.
#
# An issue that request would refuse (404, 403) is left out and listed under
# "skipped" with the reason.
class ContextMenuActionsExportController < ApplicationController
  # The helpers of IssuesController, including the ones other plugins add to it:
  # the API view calls render_api_issue_children, render_api_custom_values and
  # render_api_attachment, which a plugin may patch.
  helper IssuesController._helpers

  before_action :require_export_enabled
  before_action :find_export_issues
  before_action :authorize_export

  def issues
    entries = []
    skipped = @skipped.dup
    with_api_params do
      @openable.each do |issue|
        if issue_detail_allowed?(issue)
          entries << render_issue(issue)
        else
          skipped << skipped_entry(issue.id, 'forbidden')
        end
      end
    end

    response.headers['Cache-Control'] = 'no-store'
    send_data export_document(entries, skipped.sort_by { |entry| entry[:id] }),
              :type => 'application/json', :disposition => 'attachment', :filename => export_filename
  end

  private

  def require_export_enabled
    render_404 unless RedmineContextMenuActions.export_json_enabled?
  end

  # ids[] as the context menu link sends them (id= as well, like core's
  # find_issues). The limit is checked before anything is loaded, and a request
  # over it gets no file at all.
  def find_export_issues
    ids = Array(params[:ids] || params[:id]).select { |id| id.is_a?(String) || id.is_a?(Integer) }
    # Within the integer column: a larger value would make Active Record raise.
    ids = ids.map(&:to_s).grep(/\A\d{1,10}\z/).map(&:to_i).grep(1..2_147_483_647).uniq
    return render_404 if ids.empty?

    limit = RedmineContextMenuActions.export_json_limit
    if ids.size > limit
      flash[:error] = l(:text_cma_export_limit_exceeded, :count => ids.size, :max => limit)
      return redirect_back_or_default(issues_path)
    end

    issues = Issue.where(:id => ids).preload(:project, :tracker, :status).to_a
    return render_404 if issues.empty?

    found = issues.map(&:id)
    @skipped = (ids - found).map { |id| skipped_entry(id, 'not_found') }
    visible, invisible = issues.partition(&:visible?)
    @skipped += invisible.map { |issue| skipped_entry(issue.id, 'forbidden') }
    @openable = visible.sort_by(&:id)
    @projects = @openable.map(&:project).uniq
    @project = @projects.first if @projects.size == 1
  end

  # The permission on the project of every issue the user can see; nothing
  # visible, nothing to export.
  def authorize_export
    deny_access if @openable.empty? || !User.current.allowed_to?(:export_issues_json, @projects)
  end

  # What GET /issues/:id.json checks after find_issue: core's authorize for
  # issues#show, then the before_action redmine_view_issue_description adds
  # (vid_authorize_issue_detail), which refuses the issue to a user who may not
  # open it.
  def issue_detail_allowed?(issue)
    return false unless issue.visible?
    return false unless User.current.allowed_to?({:controller => 'issues', :action => 'show'}, issue.project)
    return false if issue.respond_to?(:detail_access_granted?) && !issue.detail_access_granted?(User.current)
    return false if core_fields_hidden_in_ui_only?(issue)

    true
  end

  # redmine_issue_field_visibility without hide_values (its 5.1 version) hides
  # core fields in the UI only; the API view still shows them. The REST API may
  # be off, so the file must not show what the UI hides: an issue with a core
  # field hidden from the user is refused. With hide_values the API view hides
  # the fields itself, and the file is that view.
  def core_fields_hidden_in_ui_only?(issue)
    return false unless defined?(::RedmineIssueFieldVisibility)
    return false if ::RedmineIssueFieldVisibility.respond_to?(:hide_values)

    ::RedmineIssueFieldVisibility.hidden_core_fields(User.current, issue.project).present?
  end

  # The API view reads params[:format] (which builder) and params[:include]
  # (which parts), as on GET /issues/:id.json?include=... . JSONP is never
  # applied to the file: the builder reads callback from the request.
  def with_api_params
    request.parameters.delete('callback')
    request.parameters.delete('jsonp')
    params[:format] = 'json'
    params[:include] = RedmineContextMenuActions.export_json_include.join(',')
    yield
  ensure
    params.delete(:format)
    params.delete(:include)
  end

  # IssuesController#show for format.api: the same instance variables, set the
  # same way, then core's view.
  def render_issue(issue)
    @issue = issue
    @project = issue.project
    @journals = @relations = @changesets = @allowed_statuses = nil

    if include_part?('journals')
      @journals = @issue.visible_journals_with_index
      @journals.reverse! if User.current.wants_comments_in_reverse_order?
    end
    @relations = @issue.relations.select { |r| r.other_issue(@issue)&.visible? } if include_part?('relations')
    if User.current.allowed_to?(:view_time_entries, @project)
      Issue.load_visible_spent_hours([@issue])
      Issue.load_visible_total_spent_hours([@issue])
    end
    if include_part?('changesets')
      @changesets = @issue.changesets.visible.preload(:repository, :user).to_a
      @changesets.reverse! if User.current.wants_comments_in_reverse_order?
    end

    issue_json(render_to_string(:template => 'issues/show', :formats => [:api], :layout => false))
  end

  def include_part?(part)
    RedmineContextMenuActions.export_json_include.include?(part)
  end

  # The builder writes {"issue":{...}}; the entry is the object inside, byte for
  # byte.
  def issue_json(body)
    prefix = '{"issue":'
    if body.start_with?(prefix) && body.end_with?('}')
      body[prefix.length...-1]
    else
      JSON.parse(body).fetch('issue').to_json
    end
  end

  def skipped_entry(id, reason)
    {:id => id, :reason => reason}
  end

  # The wrapper is generated, the entries are inserted as rendered.
  def export_document(entries, skipped)
    user = User.current
    head = {
      :exported_on => Time.now.utc.xmlschema(0),
      :exported_by => (user.logged? ? {:id => user.id, :name => user.name} : nil),
      :redmine_version => Redmine::VERSION.to_s
    }.to_json
    tail = {:skipped => skipped}.to_json
    "#{head[0...-1]},\"issues\":[#{entries.join(',')}],#{tail[1..]}"
  end

  def export_filename
    "issues-#{Time.now.strftime('%Y%m%d-%H%M%S')}.json"
  end
end
