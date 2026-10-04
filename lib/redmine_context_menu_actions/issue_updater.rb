# frozen_string_literal: true

module RedmineContextMenuActions
  # Applies one change to each issue the way IssuesController#bulk_update does:
  # reload, init_journal, safe_attributes=, the
  # controller_issues_bulk_edit_before_save hook, save. So validation, workflow,
  # updated_on, journals, notifications, @mentions and other plugins' hooks
  # behave as for a change made in core.
  #
  # Issues are saved one by one, as core does: one failing issue does not undo the
  # others, and the result says per issue what happened, so a retry can target
  # exactly the issues that failed and never add a second note to one that saved.
  class IssueUpdater
    ATTRIBUTES = %w[notes private_notes start_date due_date].freeze

    Result = Struct.new(:issue, :saved, :errors) do
      def saved?
        saved
      end
    end

    # attributes: whitelisted issue attributes, values as the form posts them.
    # params, hook_context: what core passes to the bulk edit hook.
    # since: when the dialog was opened. A note this user already added to an
    # issue since then, word for word, is not added again: the response to the
    # first submit was lost and the user submitted once more. The other
    # attributes are still applied; unchanged, they change nothing.
    def initialize(issues, user:, attributes:, params: {}, hook_context: {}, since: nil)
      unknown = attributes.keys.map(&:to_s) - ATTRIBUTES
      raise ArgumentError, "not allowed: #{unknown.join(', ')}" if unknown.any?

      @issues = issues
      @user = user
      @attributes = attributes.to_h { |key, value| [key.to_s, value] }
      @params = params
      @hook_context = hook_context
      @since = since
    end

    def call
      @issues.map { |issue| update(issue) }
    end

    private

    # Each issue is saved in its own transaction, on a fresh copy locked for
    # update: a second request for the same issue (the same note submitted
    # again while the first request still runs) waits for the first to commit,
    # and then finds its note. One stale object (a change made before the lock)
    # is retried, checking again; a second conflict is reported. Any other error
    # is reported for this issue only, never turned into an error page: the
    # issues already saved would then be submitted again.
    def update(issue)
      2.times do
        return Issue.transaction { apply(Issue.lock.find(issue.id)) }
      rescue ActiveRecord::StaleObjectError
        next
      end
      Result.new(issue, false, [::I18n.t(:notice_issue_update_conflict)])
    rescue StandardError => e
      log_failure(issue, e)
      Result.new(issue, false, [])
    end

    def apply(issue)
      attributes = already_noted?(issue) ? @attributes.except('notes', 'private_notes') : @attributes
      return Result.new(issue, true, []) if attributes.empty?
      return refused(issue) unless allowed?(issue, attributes)

      issue.init_journal(@user)
      issue.send(:safe_attributes=, attributes, @user)
      Redmine::Hook.call_hook(:controller_issues_bulk_edit_before_save,
                              @hook_context.merge(:params => @params, :issue => issue))
      if issue.save
        Result.new(issue, true, [])
      else
        Result.new(issue, false, issue.errors.full_messages)
      end
    end

    # This user added the same text, public or private as asked, to this issue
    # since the dialog opened. The text is compared again in Ruby: a MySQL
    # collation compares case and trailing spaces loosely.
    def already_noted?(issue)
      notes = @attributes['notes']
      return false unless @since && notes.is_a?(String) && notes.present?

      Journal.where(:journalized_type => 'Issue', :journalized_id => issue.id, :user_id => @user.id,
                    :notes => notes, :private_notes => private_notes?)
             .where("#{Journal.table_name}.created_on >= ?", @since)
             .pluck(:notes).any?(notes)
    end

    def private_notes?
      ActiveModel::Type::Boolean.new.cast(@attributes['private_notes']) || false
    end

    # The message of a database error carries the SQL, note text included, so
    # only its class is logged.
    def log_failure(issue, error)
      message = error.is_a?(ActiveRecord::StatementInvalid) ? '(statement omitted)' : error.message
      Rails.logger.error("[redmine_context_menu_actions] issue ##{issue.id}: #{error.class}: #{message}\n" \
                         "#{Array(error.backtrace).first(10).join("\n")}")
    end

    # Every attribute about to be set must be a safe attribute for this user on
    # this issue: notes need add_issue_notes, private_notes needs
    # set_notes_private, dates need edit permission and must not be read-only or
    # derived. Nothing is silently dropped.
    def allowed?(issue, attributes)
      issue.visible?(@user) && (attributes.keys - issue.safe_attribute_names(@user)).empty?
    end

    def refused(issue)
      Result.new(issue, false, [::I18n.t(:notice_not_authorized)])
    end
  end
end
