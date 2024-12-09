# spec/enhanced_errors_spec.rb

require_relative '../lib/enhanced_errors'
require_relative '../spec/spec_helper'

RSpec.describe 'Demo' do
  let(:baz) { 'bee'}

  before do
    @yo = 'sup'
  end

  it 'does something' do
    foo = 'bar'
    baz
    expect(false).to eq(true)
  end

  it 'does something else' do
    something = 'else'
    expect(false).to eq(true)
  end

  it 'passes fine' do
    expect(true).to eq(true)
  end

  it 'works if it raises an errors' do
    hi = 'there'
    raise StandardError.new('crud')
  end
end