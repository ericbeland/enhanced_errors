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

  config.before(:example) do |_example|
    EnhancedErrors.start_rspec_binding_capture
  end

  config.after(:example) do |example|
    EnhancedErrors.override_rspec_message(example, EnhancedErrors.stop_rspec_binding_capture)
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

    it "dodges multiple exception-bullets at once" do
      foo = 'bar'
      expect(1).to eq(2)
      expect(true).to eq(false)
    end

    after(:each) do
      raise "This is another error"
    end

  end
end

