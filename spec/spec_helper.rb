# spec_helper.rb
require 'rspec'
require 'enhanced_errors'

RSpec.configure do |config|
  config.before(:suite) do
    RSpec::Core::Example.prepend(Enhanced::Integrations::RSpecErrorFailureMessage)
  end

  config.before(:example) do |_example|
    EnhancedErrors.start_rspec_binding_capture
  end

  config.after(:example) do |example|
    example.metadata[:expect_binding] = EnhancedErrors.stop_rspec_binding_capture
  end
end

