# frozen_string_literal: true

require_relative 'spec_helper'

# Every locale carries the same keys, none of them blank, so no screen of this
# plugin ever shows "translation missing" or an empty label.
RSpec.describe 'translations' do
  CMA_LOCALES_PATH = File.expand_path('../config/locales', __dir__)
  CMA_REFERENCE_KEYS = YAML.load_file(File.join(CMA_LOCALES_PATH, 'en.yml'))['en'].keys.sort.freeze

  # The core strings the plugin shows instead of writing its own. Redmine
  # translates them, so they read the same as everywhere else in Redmine.
  CMA_CORE_KEYS = %w[
    label_add_note label_issue_note_added label_last_notes label_x_issues
    field_notes field_private_notes field_start_date field_due_date
    button_submit button_cancel button_clear
    notice_successful_update notice_failed_to_save_issues notice_not_authorized
    notice_file_not_found notice_issue_update_conflict error_invalid_authenticity_token
    error_session_expired text_warn_on_leaving_unsaved
  ].freeze

  it 'ships the 50 languages Redmine ships' do
    expect(Dir[File.join(CMA_LOCALES_PATH, '*.yml')].size).to eq(50)
  end

  Dir[File.join(CMA_LOCALES_PATH, '*.yml')].each do |path|
    locale = File.basename(path, '.yml')

    describe locale do
      let(:translations) { YAML.load_file(path)[locale] }

      it 'is keyed by its own locale' do
        expect(translations).to be_a(Hash)
      end

      it 'covers exactly the keys of the English reference' do
        expect(translations.keys.sort).to eq(CMA_REFERENCE_KEYS)
      end

      it 'has no blank value' do
        expect(translations.reject { |_, v| v.to_s.strip.present? }).to be_empty
      end

      it 'uses no en dash or em dash' do
        expect(translations.values.grep(/[\u2013\u2014]/)).to eq([])
      end

      # Read from core's own file rather than through I18n, whose fallback to
      # English would make a missing key look present.
      it 'finds every core string the plugin reuses in core' do
        core = YAML.load_file(Rails.root.join('config', 'locales', "#{locale}.yml"))[locale]
        expect(CMA_CORE_KEYS.reject { |key| core.key?(key) }).to eq([])
      end
    end
  end

  # The locale files are written as plain YAML, so a stray English value copied
  # into another language is the likely mistake. English is allowed where the word
  # is the same, which is why this lists exceptions instead of failing on any match.
  it 'does not paste the English text into other languages' do
    english = YAML.load_file(File.join(CMA_LOCALES_PATH, 'en.yml'))['en']
    same_word = {
      'label_cma_dates' => %w[en-GB fr ca] # "Dates" is the French and Catalan word too
    }

    Dir[File.join(CMA_LOCALES_PATH, '*.yml')].each do |path|
      locale = File.basename(path, '.yml')
      next if %w[en en-GB].include?(locale)

      YAML.load_file(path)[locale].each do |key, value|
        next unless value == english[key]
        next if same_word.fetch(key, []).include?(locale)

        raise "#{locale}.#{key} is the English text #{value.inspect}"
      end
    end
  end
end
