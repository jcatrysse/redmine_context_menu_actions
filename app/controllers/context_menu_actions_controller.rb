# frozen_string_literal: true

# The endpoints behind the context menu actions. They load the selected issues
# with core's find_issues (404 when none exist, 403 when one is not visible) and
# authorize with the same predicate the menu uses, so a request the menu would
# never have offered is refused rather than half applied.
class ContextMenuActionsController < ApplicationController
  helper :queries

  before_action :find_issues
  before_action :sort_issues
  before_action :require_notes_enabled, :authorize_notes, :only => [:new_note, :create_note]
  before_action :require_dates_enabled, :authorize_dates, :only => [:edit_dates, :update_dates]

  def new_note
    @private_notes_allowed = predicates.private_notes_allowed?(@issues)
    @column_names = column_names_param

    respond_to do |format|
      format.js
      format.html { redirect_to(@issues.size == 1 ? edit_issue_path(@issues.first) : _project_issues_path(@project)) }
    end
  end

  def create_note
    @column_names = column_names_param
    notes = notes_param

    if notes.strip.empty?
      refuse(blank_notes_message)
    elsif private_requested? && !predicates.private_notes_allowed?(@issues)
      # Asked for a private note without set_notes_private on every issue. Refused
      # rather than published: the text was meant for fewer eyes.
      refuse(l(:notice_not_authorized))
    else
      attributes = {'notes' => notes}
      attributes['private_notes'] = '1' if private_requested?
      apply(attributes)
    end
    respond_with_results(l(:label_issue_note_added))
  end

  def edit_dates
    @column_names = column_names_param
    @notes_allowed = predicates.notes_addable?(@issues)
    @date_values = @date_fields.index_with do |field|
      values = @issues.map { |issue| issue.send(field) }.uniq
      {:value => (values.size == 1 ? values.first : nil), :mixed => values.size > 1}
    end

    respond_to do |format|
      format.js
      format.html { redirect_to(@issues.size == 1 ? edit_issue_path(@issues.first) : bulk_edit_issues_path(:ids => @issues.map(&:id))) }
    end
  end

  def update_dates
    @column_names = column_names_param
    attributes = {}
    refused = false

    predicates::DATE_FIELDS.each do |field|
      value = issue_param(field).to_s.strip
      # Empty means "no change", as in core's bulk edit; "none" clears the date.
      next if value.empty?

      refused ||= !@date_fields.include?(field)
      attributes[field] = (value == 'none' ? '' : value)
    end
    notes = notes_param
    unless notes.strip.empty?
      refused ||= !predicates.notes_addable?(@issues)
      attributes['notes'] = notes
    end

    # A value for a field the user may not change is refused as a whole rather
    # than applied in part.
    if refused
      refuse(l(:notice_not_authorized))
    else
      apply(attributes)
    end
    @reload = true
    respond_with_results(l(:notice_successful_update))
  end

  private

  def predicates
    RedmineContextMenuActions::Predicates
  end

  def sort_issues
    @issues = @issues.sort_by(&:id)
  end

  def require_notes_enabled
    render_404 unless RedmineContextMenuActions.notes_enabled?
  end

  def authorize_notes
    deny_access unless predicates.notes_addable?(@issues)
  end

  def require_dates_enabled
    render_404 unless RedmineContextMenuActions.dates_enabled?
  end

  # The date fields every selected issue lets this user change; none, and the
  # menu would not have offered the action.
  def authorize_dates
    @date_fields = predicates.date_fields(predicates.common_safe_attribute_names(@issues))
    deny_access if @date_fields.empty?
  end

  def private_requested?
    issue_param(:private_notes) == '1'
  end

  # Parameters as the forms post them. Anything else (issue=foo, notes[]=x) is
  # treated as absent rather than raising.
  def issue_param(key)
    issue = params[:issue]
    issue.respond_to?(:key?) ? issue[key] : nil
  end

  def notes_param
    params[:notes].is_a?(String) ? params[:notes] : ''
  end

  def refuse(message)
    @results = []
    @request_errors = [message]
  end

  def apply(attributes)
    @request_errors = []
    # Core's bulk edit form always posts issue[...]; a bulk edit hook of another
    # plugin may read params[:issue] without checking it is there.
    params[:issue] = {} unless params[:issue].respond_to?(:key?)
    @results =
      if attributes.empty?
        []
      else
        RedmineContextMenuActions::IssueUpdater.new(
          @issues,
          :user => User.current,
          :attributes => attributes,
          :params => params,
          :hook_context => {:controller => self, :request => request, :project => @project, :hook_caller => self},
          :since => dialog_opened_at
        ).call
      end
  end

  # When the dialog was rendered (its form carries it), so a note submitted a
  # second time after a lost response is recognised. Ignored when absent or
  # implausible.
  def dialog_opened_at
    value = params[:cma_since].to_s
    return unless value.match?(/\A\d{9,11}\z/)

    time = Time.zone.at(value.to_i)
    time if time.between?(1.day.ago, 1.minute.from_now)
  end

  # Echoed in the response, so the page applies it to the dialog that sent it
  # and to no other.
  def dialog_token
    params[:cma_dialog].to_s[/\A[\w-]{1,40}\z/]
  end
  helper_method :dialog_token

  # The columns of the issue list the dialog was opened from, as core's own list
  # form posts them (c[]). They tell the response whether and where that list
  # shows the Last notes block.
  def column_names_param
    RedmineContextMenuActions.column_names(params[:c])
  end

  def respond_with_results(notice)
    @notice = notice
    @saved_issues = @results.select(&:saved?).map(&:issue)
    @failed_results = @results.reject(&:saved?)
    @remaining_issues = @request_errors.any? ? @issues : @failed_results.map(&:issue)

    # Last notes are read back once for every saved issue, with core's own
    # visibility rule for private notes.
    Issue.load_visible_last_notes(@saved_issues, User.current) if @saved_issues.any?
    @last_notes_column = IssueQuery.available_columns.detect { |column| column.name == :last_notes }
    @last_notes_layout = last_notes_layout

    respond_to do |format|
      format.js { render :saved }
      format.html { redirect_after_html_submit }
    end
  end

  # Where the list puts a Last notes row that does not exist yet: after the block
  # rows that come before it, with a caption when the list shows more than one
  # block column. Nil when the list does not show Last notes at all.
  def last_notes_layout
    return unless @column_names.include?('last_notes')

    query = IssueQuery.new(:name => '_', :column_names => @column_names)
    blocks = query.block_columns
    {
      :order => blocks.map { |column| column.css_classes.to_s.split.first },
      :caption => (blocks.size > 1 ? @last_notes_column.caption : nil)
    }
  end

  def blank_notes_message
    errors = ActiveModel::Errors.new(Journal.new)
    errors.add(:notes, :blank)
    errors.full_messages.first
  end

  # Without JavaScript the dialogs cannot be opened, but a plain POST still gets
  # an answer instead of a missing template.
  def redirect_after_html_submit
    if @request_errors.any? || @failed_results.any?
      messages = (@request_errors + @failed_results.flat_map(&:errors)).uniq
      messages = [helpers.cma_failed_message(@remaining_issues, @issues.size)] if messages.empty?
      flash[:error] = messages.join(' ')
    else
      flash[:notice] = @notice
    end
    redirect_back_or_default(@issues.size == 1 ? issue_path(@issues.first) : _project_issues_path(@project))
  end
end
