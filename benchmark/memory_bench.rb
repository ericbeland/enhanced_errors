# benchmark_tracepoint.rb

def memory_usage
  pid = Process.pid
  `ps -o rss= -p #{pid}`.to_i  # Returns memory usage in KB
end

# Generate a 100 MB string outside the iterations
large_string = 'a' * 10_000_000  # 10 million characters

def test_with_tracepoint(iterations, large_string)
  puts "\nTest with TracePoint capturing bindings:"
  captured_bindings = []

  trace = TracePoint.new(:raise) do |tp|
    captured_bindings << tp.binding
  end

  trace.enable

  puts "Memory usage before exceptions: #{memory_usage} KB"

  iterations.times do
    begin
      # Use the large string within the local scope
      local_large_string = large_string
      raise 'Test exception'
    rescue => e
      raise e rescue nil  # Suppress the exception to continue the loop
    end
  end

  puts "Memory usage after exceptions: #{memory_usage} KB"

  trace.disable
end

def test_without_tracepoint(iterations, large_string)
  puts "\nTest without TracePoint capturing bindings:"

  puts "Memory usage before exceptions: #{memory_usage} KB"

  iterations.times do
    begin
      # Use the large string within the local scope
      local_large_string = large_string
      raise 'Test exception'
    rescue => e
      raise e rescue nil
    end
  end

  puts "Memory usage after exceptions: #{memory_usage} KB"
end

def test_exception_with_large_variable(iterations, large_string)
  puts "\nTest with exceptions storing large variable:"

  puts "Memory usage before exceptions: #{memory_usage} KB"

  iterations.times do
    begin
      raise 'Test exception'
    rescue => e
      # Store a reference to the large string in the exception
      e.instance_variable_set(:@large_string, large_string)
      raise e rescue nil
    end
  end

  puts "Memory usage after exceptions: #{memory_usage} KB"
end

iterations = 10000  # Adjust iterations as needed

test_with_tracepoint(iterations, large_string)
test_without_tracepoint(iterations, large_string)
test_exception_with_large_variable(iterations, large_string)
