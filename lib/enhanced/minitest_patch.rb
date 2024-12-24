module Minitest
  class << self
    alias_method :original_run_one_method, :run_one_method

    def run_one_method(klass, method_name)
      EnhancedErrors.start_minitest_binding_capture
      result = original_run_one_method(klass, method_name)
    ensure
      begin
        binding_infos = EnhancedErrors.stop_minitest_binding_capture
        EnhancedErrors.override_exception_message(result.failures.last, binding_infos) if result.failures.any?
        Enhanced::ExceptionContext.clear_all
      rescue => e
        puts "Ignored error during error enhancement: #{e}"
      end
    end
  end
end
