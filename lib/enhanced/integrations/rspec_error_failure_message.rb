module Enhanced
  module Integrations
    module RSpecErrorFailureMessage
      def execution_result
        result = super
        if result.exception
          EnhancedErrors.override_exception_message(result.exception, self.metadata[:expect_binding])
        end
        result
      end
    end
  end
end
