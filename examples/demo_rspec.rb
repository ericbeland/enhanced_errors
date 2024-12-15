# spec/enhanced_errors_spec.rb

# INSTRUCTIONS:  Install rspec
# gem install rspec
# rspec examples/example_spec.rb

require 'rspec'
require_relative '../lib/enhanced_errors'

RSpec.configure do |config|

  # -- Add to your RSPec config in your spec_helper.
  config.before(:example) do |_example|
    EnhancedErrors.start_rspec_binding_capture
  end

  config.after(:example) do |example|
    EnhancedErrors.override_exception_message(example.exception, EnhancedErrors.stop_rspec_binding_capture)
  end
  # -- End EnhancedErrors config

end


RSpec.describe 'Neo' do
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

