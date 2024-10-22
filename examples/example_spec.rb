require 'rspec'
require_relative '../lib/enhanced_errors'

# INSTRUCTIONS:  Install rspec
# gem install rspec
# rspec examples/example_spec.rb

RSpec.describe EnhancedErrors do
  before(:each) do
    EnhancedErrors.enhance!
  end

  describe 'Exception enhancement' do
    let(:my_let_variable) { 'sweet!' }

    before(:each) do
      @foo = 'bar'
    end

    it 'shows me some variables!' do
      #activate memoized item
      my_let_variable
      my_local = 'value'
      raise 'This is an error!'
    end
  end
end
