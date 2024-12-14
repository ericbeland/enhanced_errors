# spec_helper.rb
require 'rspec'
require 'enhanced_errors'

RSpec.configure do |config|
  config.before(:example) do |_example|
    EnhancedErrors.enhance_exceptions!
    EnhancedErrors.start_rspec_binding_capture
  end

  config.after(:example) do |example|
    EnhancedErrors.override_exception_message(example.exception, EnhancedErrors.stop_rspec_binding_capture)
  end
end

