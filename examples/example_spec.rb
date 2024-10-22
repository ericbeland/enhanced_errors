require 'rspec'
require_relative '../lib/enhanced_errors'

# INSTRUCTIONS:  Install rspec
# gem install rspec
# rspec examples/example_spec.rb

RSpec.describe 'Neo' do
  before(:each) do
    EnhancedErrors.enhance!
  end

  describe 'attains enlightenment' do
    let(:the_matrix) { 'code rains, dramatically' }

    before(:each) do
      @spoon = 'there is no spoon'
    end

    it 'in the matrix' do
      #activate memoized item
      the_matrix
      stop = 'bullets'
      raise 'No!'
    end
  end
end
