require 'benchmark'
require_relative '../lib/enhanced_errors' # Adjust the path if necessary

#require 'profile'

# In general, the results of this are--catching exception bindings is pretty cheap.
# However, catching :call, :return, :b_return, :b_call are 100x more expensive.
# Makes sense if you think about the relative frequency of things.


# Define the number of iterations
ITERATIONS = 1_000
EXCEPTIONS_PER_BATCH = 100

class Boo < StandardError; end

def calculate_cost(time_in_seconds)
  milliseconds = time_in_seconds * 1000
  (milliseconds / (ITERATIONS / EXCEPTIONS_PER_BATCH)).round(2)
end


def raise_errors
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
  rxp = /Boo/
  EnhancedErrors.enhance_exceptions!(debug: false) do
    eligible_for_capture { |exception| !!rxp.match(exception.class.to_s) }
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
  rxp = /Baz/
  EnhancedErrors.enhance_exceptions!(override_messages: true) do
    eligible_for_capture { |exception| !!rxp.match(exception.class.to_s) }
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
  without_time = x.report('Baseline 1k (NO EnhancedErrors, tight error raise loop):') { raise_errors }
end

puts "\n"
EnhancedErrors.enhance_exceptions!(debug: false)

Benchmark.bm(35) do |x|
  with_time = x.report('Stress 1k EnhancedErrors  (Tight error raising loop w/ EnhancedErrors):') { raise_errors }
  puts "Cost per 100 raised exceptions: #{calculate_cost(with_time.real)} ms"
end


# puts "\nProof that if you only match the classes you care about, the cost is nominal\n"
# Benchmark.bm(35) do |x|
#   matched_time = x.report('1k capture_only_regexp match (same as always-on) :') { when_capture_only_regexp_matched }
#   not_matched_time = x.report('1k capture_only_regexp not matching (low-cost):') { when_capture_only_regexp_did_not_match }
#
#   puts "\nCost per 100 exceptions (Capture Only Match): #{calculate_cost(matched_time.real)} ms"
#   puts "Cost per 100 exceptions (No Match): #{calculate_cost(not_matched_time.real)} ms"
# end
