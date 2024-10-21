require 'benchmark'
require_relative '../lib/enhanced_errors' # Adjust the path if necessary

# Define the number of iterations
ITERATIONS = 10_000
EXCEPTIONS_PER_BATCH = 100

class Boo < StandardError; end

def calculate_cost(time_in_seconds)
  milliseconds = time_in_seconds * 1000
  (milliseconds / (ITERATIONS / EXCEPTIONS_PER_BATCH)).round(2)
end

def with_enhanced_errors
  EnhancedErrors.enhance!(debug: false)
  ITERATIONS.times do
    begin
      foo = 'bar'
      @boo = 'baz'
      raise 'Test exception with EnhancedErrors'
    rescue => e
      e.message
    end
  end
end

def without_enhanced_errors
  ITERATIONS.times do
    begin
      foo = 'bar'
      @boo = 'baz'
      raise 'Test exception without EnhancedErrors'
    rescue => e
      e.message
    end
  end
end

def when_capture_only_regexp_matched
  EnhancedErrors.enhance!(debug: false) do
    eligible_for_capture { |exception| !!/Boo/.match(exception.class.to_s) }
  end

  ITERATIONS.times do
    begin
      foo = 'bar'
      @boo = 'baz'
      raise Boo.new('Test exception with EnhancedErrors')
    rescue => e
      e.message
    end
  end
end

def when_capture_only_regexp_did_not_match
  EnhancedErrors.enhance!(debug: false) do
    eligible_for_capture { |exception| !!/Baz/.match(exception.class.to_s) }
  end

  ITERATIONS.times do
    begin
      foo = 'bar'
      @boo = 'baz'
      raise Boo.new('Test exception with EnhancedErrors')
    rescue => e
      e.message
    end
  end
end

puts "Cost Exploration\n"
Benchmark.bm(35) do |x|
  without_time = x.report('10k Without EnhancedErrors:') { without_enhanced_errors }
  with_time = x.report('10k With EnhancedErrors:') { with_enhanced_errors }

  puts "\nCost per 100 exceptions (Without EnhancedErrors): #{calculate_cost(without_time.real)} ms"
  puts "Cost per 100 exceptions (With EnhancedErrors): #{calculate_cost(with_time.real)} ms"
end

puts "\nProof that if you only match the classes you care about, the cost is nominal\n"
Benchmark.bm(35) do |x|
  matched_time = x.report('10k With capture_only_regexp match:') { when_capture_only_regexp_matched }
  not_matched_time = x.report('10k Without capture_only_regexp match:') { when_capture_only_regexp_did_not_match }

  puts "\nCost per 100 exceptions (Capture Only Match): #{calculate_cost(matched_time.real)} ms"
  puts "Cost per 100 exceptions (No Match): #{calculate_cost(not_matched_time.real)} ms"
end
