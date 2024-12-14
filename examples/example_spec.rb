require 'rspec'
require_relative '../lib/enhanced_errors'
require_relative '../spec/spec_helper'
# INSTRUCTIONS:  Install rspec
# gem install rspec
# rspec examples/example_spec.rb

RSpec.describe 'Neo' do
  before(:each) do
    # EnhancedErrors.enhance_exceptions!(override_messages: true)
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

