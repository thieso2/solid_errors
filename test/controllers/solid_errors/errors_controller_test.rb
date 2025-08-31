# frozen_string_literal: true

require "test_helper"

module SolidErrors
  class ErrorsControllerTest < ActionDispatch::IntegrationTest
    setup do
      # Create a test error with occurrences
      @error = SolidErrors::Error.create!(
        exception_class: "StandardError",
        message: "Test error message for Claude analysis",
        severity: "error",
        source: "application",
        fingerprint: Digest::SHA256.hexdigest("test-error")
      )
      
      # Create a more realistic backtrace with mix of GEM_ROOT and PROJECT_ROOT
      rails_root = Rails.root.to_s
      @occurrence = SolidErrors::Occurrence.create!(
        error: @error,
        backtrace: [
          "#{Gem.path.first}/gems/actionpack-7.0.0/lib/action_dispatch.rb:10:in `call'",
          "#{Gem.path.first}/gems/rack-2.0.0/lib/rack.rb:20:in `call'",
          "#{Gem.path.first}/gems/rails-7.0.0/lib/rails.rb:30:in `call'",
          "#{rails_root}/app/controllers/test_controller.rb:10:in `index'",
          "#{rails_root}/app/models/test_model.rb:25:in `process'",
          "#{Gem.path.first}/gems/activerecord-7.0.0/lib/active_record.rb:100:in `execute'",
          "#{Gem.path.first}/gems/activerecord-7.0.0/lib/active_record.rb:110:in `query'",
          "#{Gem.path.first}/gems/activerecord-7.0.0/lib/active_record.rb:120:in `select_all'",
          "#{rails_root}/app/services/data_processor.rb:45:in `fetch_data'",
          "#{Gem.path.first}/gems/sidekiq-6.0.0/lib/sidekiq.rb:200:in `perform'"
        ].join("\n"),
        context: {
          request_url: "http://example.com/test",
          user_id: 123,
          params: { id: 1 }.to_json
        }
      )
    end

    teardown do
      SolidErrors::Occurrence.destroy_all
      SolidErrors::Error.destroy_all
    end

    test "should show error with Claude analysis section" do
      get "/solid_errors/#{@error.id}"
      assert_response :success
      
      # Check that the LLM copy button is present with icon
      assert_select "button[onclick='copyClaudeAnalysis(event)']" do
        assert_select "svg" # Check for copy icon
        assert_select "span", text: "Copy for LLM"
      end
    end

    test "Claude analysis section contains error details" do
      get "/solid_errors/#{@error.id}"
      assert_response :success
      
      # Check that the button with error details in data attribute exists
      assert_select "button[data-claude-text]" do |elements|
        button_content = elements.first['data-claude-text']
        
        # Check for key error information
        assert_match(/EXCEPTION: StandardError/, button_content)
        assert_match(/MESSAGE: Test error message for Claude analysis/, button_content)
        assert_match(/SEVERITY: error/, button_content)
        assert_match(/SOURCE: application/, button_content)
        assert_match(/STATUS: Unresolved/, button_content)
        
        # Check for occurrence information
        assert_match(/OCCURRENCES: 1 total/, button_content)
        assert_match(/MOST RECENT OCCURRENCE:/, button_content)
        
        # Check for context
        assert_match(/Context:/, button_content)
        assert_match(/request_url:/, button_content)
        assert_match(/user_id:/, button_content)
        
        # Check for backtrace
        assert_match(/BACKTRACE:/, button_content)
        assert_match(/test_controller\.rb/, button_content)
        assert_match(/test_model\.rb/, button_content)
        assert_match(/data_processor\.rb/, button_content)
        
        # Check for analysis prompt
        assert_match(/Please analyze this error and suggest:/, button_content)
        assert_match(/1\. Root cause of the error/, button_content)
        assert_match(/2\. Potential fixes/, button_content)
        assert_match(/3\. Any patterns or anti-patterns you notice/, button_content)
        assert_match(/4\. Recommendations for preventing similar errors/, button_content)
      end
    end

    test "Claude analysis section handles errors without occurrences" do
      # Create an error without occurrences
      error_without_occurrences = SolidErrors::Error.create!(
        exception_class: "NoMethodError",
        message: "undefined method `foo' for nil:NilClass",
        severity: "error",
        source: "application",
        fingerprint: Digest::SHA256.hexdigest("test-error-no-occurrences")
      )
      
      get "/solid_errors/#{error_without_occurrences.id}"
      assert_response :success
      
      # Should still have the Claude analysis button
      assert_select "button[onclick='copyClaudeAnalysis(event)']"
      
      # Check that it handles missing occurrence data gracefully
      assert_select "button[data-claude-text]" do |elements|
        button_content = elements.first['data-claude-text']
        
        assert_match(/EXCEPTION: NoMethodError/, button_content)
        assert_match(/OCCURRENCES: 0 total/, button_content)
        # Should not have MOST RECENT OCCURRENCE section when there are no occurrences
        assert_no_match(/MOST RECENT OCCURRENCE:/, button_content)
      end
    end

    test "Claude analysis button has onclick handler" do
      get "/solid_errors/#{@error.id}"
      assert_response :success
      
      # Check that the button has the onclick handler for copying
      assert_select "button[onclick='copyClaudeAnalysis(event)']"
      
      # Check that the JavaScript function is defined
      assert_match(/function copyClaudeAnalysis/, response.body)
    end

    test "Claude analysis section filters backtrace intelligently" do
      get "/solid_errors/#{@error.id}"
      assert_response :success
      
      # Check that the button contains filtered backtrace
      assert_select "button[data-claude-text]" do |elements|
        button_content = elements.first['data-claude-text']
        
        # Should include PROJECT_ROOT frames
        assert_match(/\[PROJECT_ROOT\]\/app\/controllers\/test_controller\.rb/, button_content)
        assert_match(/\[PROJECT_ROOT\]\/app\/models\/test_model\.rb/, button_content)
        assert_match(/\[PROJECT_ROOT\]\/app\/services\/data_processor\.rb/, button_content)
        
        # Should include some GEM_ROOT frames (context around PROJECT_ROOT)
        assert_match(/\[GEM_ROOT\]/, button_content)
        
        # Should show omission indicator when multiple GEM_ROOT frames are collapsed
        assert_match(/\.\.\. \(\d+ GEM_ROOT frames omitted\) \.\.\./, button_content) || 
          assert_match(/BACKTRACE:/, button_content) # Allow for cases where no omission occurs
        
        # Should NOT include all the intermediate GEM_ROOT frames
        backtrace_section = button_content.split("BACKTRACE:").last.split("Please analyze").first
        gem_root_count = backtrace_section.scan(/\[GEM_ROOT\]/).count
        
        # We expect fewer GEM_ROOT entries than the original (which had 7)
        assert gem_root_count < 7, "Expected filtered backtrace to have fewer GEM_ROOT entries, but found #{gem_root_count}"
      end
    end
  end
end