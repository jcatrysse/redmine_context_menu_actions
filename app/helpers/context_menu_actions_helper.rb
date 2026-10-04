# frozen_string_literal: true

module ContextMenuActionsHelper
  # "Bug #12: Subject", as core names an issue. Plain text: the view escapes it
  # once. (The truncate view helper escapes too, which would escape it twice.)
  # The project is added when the selection spans several projects.
  def cma_issue_label(issue, with_project: false, length: 80)
    label = "#{issue.tracker} ##{issue.id}: #{issue.subject.to_s.truncate(length)}"
    label = "#{issue.project} - #{label}" if with_project
    label
  end

  # The data attributes core gives its own notes textarea: inline autocomplete
  # for @mentions and #issues, plus the list autofill of 6.1 and the textarea
  # Stimulus controllers of 7.0.
  def cma_textarea_data
    data = {:auto_complete => true}
    if respond_to?(:wiki_textarea_stimulus_attributes)
      data.merge(wiki_textarea_stimulus_attributes)
    elsif respond_to?(:list_autofill_data_attributes)
      data.merge(list_autofill_data_attributes)
    else
      data
    end
  end

  # Preview in the context of the issue, as the issue page does; for several
  # issues the plain text preview, as core's bulk edit does.
  def cma_preview_url(issues)
    if issues.size == 1
      preview_issue_path(:project_id => issues.first.project, :issue_id => issues.first)
    else
      preview_text_path
    end
  end

  # The @mention source core sets on the issue page and on bulk edit. Core only
  # offers it with add_issue_watchers, because that permission authorizes the
  # autocomplete action; without it there are no suggestions, as in core.
  def cma_mentions_url(issues, projects)
    return unless User.current.allowed_to?(:add_issue_watchers, projects)

    if issues.size == 1
      watchers_autocomplete_for_mention_path(:project_id => issues.first.project, :q => '',
                                             :object_type => 'issue', :object_id => issues.first.id)
    else
      watchers_autocomplete_for_mention_path(:q => '', :object_type => 'issue', :object_id => issues.map(&:id))
    end
  end

  def cma_failed_message(issues, total)
    l(:notice_failed_to_save_issues, :count => issues.size, :total => total,
                                     :ids => issues.map { |issue| "##{issue.id}" }.join(', '))
  end

  # The messages the dialog shows for a request that did not get an answer it
  # could render, in the user's language.
  def cma_form_data(_issues)
    {
      # Asked before typed text is lost, unless the user switched core's
      # "Warn me when leaving a page with unsaved text" off, as core does.
      'cma-leave' => (l(:text_warn_on_leaving_unsaved) unless User.current.pref.warn_on_leaving_unsaved == '0'),
      'cma-error-401' => l(:error_session_expired),
      'cma-error-403' => l(:notice_not_authorized),
      'cma-error-404' => l(:notice_file_not_found),
      'cma-error-422' => l(:error_invalid_authenticity_token),
      # No answer, or a server error: the outcome is unknown. A second submit is
      # safe, IssueUpdater does not add the same note twice.
      'cma-error-other' => l(:text_cma_request_unknown)
    }
  end

  # The message core gives a due date before the start date, for the check the
  # dialog makes before it submits.
  def cma_dates_data
    errors = ActiveModel::Errors.new(Issue.new)
    errors.add(:due_date, :greater_than_start_date)
    {'cma-date-order' => errors.full_messages.first}
  end

  # Lines for core's errorExplanation box: the batch summary, then one line per
  # issue that failed with a reason.
  def cma_error_lines(request_errors, failed_results, total)
    return request_errors if request_errors.any?
    return [] if failed_results.empty?

    lines = [cma_failed_message(failed_results.map(&:issue), total)]
    failed_results.each do |result|
      result.errors.each { |message| lines << "##{result.issue.id}: #{message}" }
    end
    lines
  end
end
