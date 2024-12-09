require 'rspec'
require_relative '../lib/enhanced_errors'

# INSTRUCTIONS:  Install rspec
# gem install rspec
# rspec examples/example_spec.rb

RSpec.describe 'Neo' do
  before(:each) do
    EnhancedErrors.enhance_exceptions!(override_messages: true)
  end

  describe 'sees through' do
    let(:the_matrix) { 'code rains, dramatically' }

    before(:each) do
      @spoon = 'there is no spoon'
    end

    it 'the matrix' do
      #activate memoized item
      the_matrix
      stop = 'bullets'
      raise 'No!'
    end
  end
end

# Note:
# The approach above is unlikely to work in large codebases where there are many
# exception-based specs that verify exception messages.
#
# Instead, take this (recommended) approach:
#
# RSpec.configure do |config|
#   config.before(:suite) do
#     RSpec::Core::Example.prepend(Enhanced::Integrations::RSpecErrorFailureMessage)
#   end
#
#   config.before(:example) do |_example|
#     EnhancedErrors.start_rspec_binding_capture
#   end
#
#   config.after(:example) do |example|
#     example.metadata[:expect_binding] = EnhancedErrors.stop_rspec_binding_capture
#   end
# end