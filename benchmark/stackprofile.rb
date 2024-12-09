require 'stackprof'
require_relative '../lib/enhanced/enhanced' # Adjust the path if necessary

# gem install stackprof

# adjust path as needed
# ruby ./lib/core_ext/enhanced/benchmark/stackprofile.rb
# dumps to current folder. read the stackprof dump:
# stackprof stackprof.dump

# Define the number of iterations
ITERATIONS = 10_000

def run_with_enhanced_errors
  EnhancedErrors.enhance_exceptions!(debug: false, override_messages: true)
  ITERATIONS.times do
    begin
      raise 'Test exception with EnhancedErrors'
    rescue => _e
      # Exception handled with EnhancedErrors.
    end
  end
end

def stackprofile
  StackProf.run(mode: :wall, out: 'stackprof.dump') do
    run_with_enhanced_errors
  end
end

stackprofile
