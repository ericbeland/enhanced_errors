# enhanced_errors.rb

require 'set'
require 'json'

require_relative 'colors'
require_relative 'error_enhancements'
require_relative 'binding'

# Exception class names to ignore. Using strings to avoid uninitialized constant errors.
IGNORED_EXCEPTION_NAMES = %w[SystemExit NoMemoryError SignalException Interrupt
                             ScriptError LoadError NotImplementedError SyntaxError
                             SystemStackError Psych::BadAlias]

# Helper method to safely resolve class names to constants
def resolve_exception_class(name)
  names = name.split('::')
  names.inject(Object) do |mod, name_part|
    if mod.const_defined?(name_part, false)
      mod.const_get(name_part)
    else
      return nil
    end
  end
rescue NameError
  nil
end

# Attempt to resolve the exception classes, ignoring any that are not defined
IGNORED_EXCEPTIONS = IGNORED_EXCEPTION_NAMES.map { |name| resolve_exception_class(name) }.compact

# The EnhancedErrors class provides mechanisms to enhance exception handling by capturing
# additional context such as binding information, variables, and method arguments when exceptions are raised.
# It offers customization options for formatting and filtering captured data.
class EnhancedErrors
  class << self
    # Indicates whether EnhancedErrors is enabled.
    #
    # @return [Boolean]
    attr_accessor :enabled

    # The TracePoint objects used for tracing exceptions per thread.
    #
    # @return [Hash{Thread => TracePoint}]
    attr_accessor :traces

    # The configuration block provided during enhancement.
    #
    # @return [Proc, nil]
    attr_accessor :config_block

    # The maximum length of the formatted exception message.
    #
    # @return [Integer]
    attr_accessor :max_length

    # Hook to modify binding information upon capture.
    #
    # @return [Proc, nil]
    attr_accessor :on_capture_hook

    # Determines whether RSpec `let` variables are captured.
    #
    # @return [Boolean]
    attr_accessor :capture_let_variables

    # A proc that determines if an exception is eligible for capture.
    #
    # @return [Proc, nil]
    attr_accessor :eligible_for_capture

    # A set of variable names to exclude from binding information.
    #
    # @return [Set<Symbol>]
    attr_accessor :skip_list

    # Determines whether to capture :rescue events.
    #
    # @return [Boolean]
    attr_accessor :capture_rescue

    # Regular expression to identify gem paths.
    #
    # @return [Regexp]
    GEMS_REGEX = %r{[\/\\]gems[\/\\]}

    # The default maximum length for formatted exception messages.
    #
    # @return [Integer]
    DEFAULT_MAX_LENGTH = 2500

    # A set of RSpec-specific instance variables to skip.
    #
    # @return [Set<Symbol>]
    RSPEC_SKIP_LIST = Set.new([
                                :@fixture_cache,
                                :@fixture_cache_key,
                                :@fixture_connection_pools,
                                :@connection_subscriber,
                                :@saved_pool_configs,
                                :@loaded_fixtures,
                                :@matcher_definitions
                              ])

    # A set of Rails-specific instance variables to skip.
    #
    # @return [Set<Symbol>]
    RAILS_SKIP_LIST = Set.new([
                                :@new_record,
                                :@attributes,
                                :@association_cache,
                                :@readonly,
                                :@previously_new_record,
                                :@destroyed,
                                :@marked_for_destruction,
                                :@destroyed_by_association,
                                :@primary_key,
                                :@strict_loading,
                                :@strict_loading_mode,
                                :@mutations_before_last_save,
                                :@mutations_from_database,
                                :@relation_delegate_cache,
                                :@predicate_builder,
                                :@generated_relation_method,
                                :@find_by_statement_cache,
                                :@arel_table
                              ])

    # Gets or sets the maximum length for the formatted exception message.
    #
    # @param value [Integer, nil] The desired maximum length. If `nil`, returns the current value.
    # @return [Integer] The maximum length for the formatted message.
    def max_length(value = nil)
      if value.nil?
        @max_length ||= DEFAULT_MAX_LENGTH
      else
        @max_length = value
      end
      @max_length
    end

    # Gets or sets whether to capture RSpec `let` variables.
    #
    # @param value [Boolean, nil] The desired state. If `nil`, returns the current value.
    # @return [Boolean] Whether RSpec `let` variables are being captured.
    def capture_let_variables(value = nil)
      if value.nil?
        @capture_let_variables = @capture_let_variables.nil? ? true : @capture_let_variables
      else
        @capture_let_variables = value
      end
      @capture_let_variables
    end

    # Gets or sets whether to capture :rescue events.
    #
    # @param value [Boolean, nil] The desired state. If `nil`, returns the current value.
    # @return [Boolean] Whether :rescue events are being captured.
    def capture_rescue(value = nil)
      if value.nil?
        @capture_rescue = @capture_rescue.nil? ? false : @capture_rescue
      else
        @capture_rescue = value
      end
      @capture_rescue
    end

    # Retrieves the current skip list, initializing it with default values if not already set.
    #
    # @return [Set<Symbol>] The current skip list.
    def skip_list
      @skip_list ||= default_skip_list
    end

    # Initializes the default skip list by merging Rails and RSpec specific variables.
    #
    # @return [Set<Symbol>] The default skip list.
    def default_skip_list
      Set.new(RAILS_SKIP_LIST).merge(RSPEC_SKIP_LIST)
    end

    # Adds variables to the skip list to exclude them from binding information.
    #
    # @param vars [Symbol] The variable names to add to the skip list.
    # @return [Set<Symbol>] The updated skip list.
    def add_to_skip_list(*vars)
      skip_list.merge(vars)
    end

    # Enhances the exception handling by setting up tracing and configuration options.
    #
    # @param enabled [Boolean] Whether to enable EnhancedErrors.
    # @param debug [Boolean] Whether to enable debug mode.
    # @param options [Hash] Additional configuration options.
    # @yield [void] A block for additional configuration.
    # @return [void]
    def enhance!(enabled: true, debug: false, capture_events: nil, **options, &block)
      @output_format = nil
      @eligible_for_capture = nil
      @original_global_variables = nil
      if enabled == false
        @original_global_variables = nil
        @enabled = false
        # Disable TracePoints in all threads
        @traces.each_value { |trace| trace.disable } if @traces
      else
        @enabled = true
        @debug = debug
        @original_global_variables = global_variables

        options.each do |key, value|
          setter_method = "#{key}="
          if respond_to?(setter_method)
            send(setter_method, value)
          elsif respond_to?(key)
            send(key, value)
          else
            # Ignore unknown options or handle as needed
          end
        end

        @config_block = block_given? ? block : nil
        instance_eval(&@config_block) if @config_block

        validate_and_set_capture_events(capture_events)

        # Initialize @traces hash to keep track of TracePoints per thread
        @traces ||= {}
        # Set up TracePoint in the main thread
        start_tracing(Thread.current)

        # Set up TracePoint in all existing threads
        Thread.list.each do |thread|
          next if thread == Thread.current
          start_tracing(thread)
        end

        # Hook into Thread creation to set up TracePoint in new threads
        override_thread_new
      end
    end

    # Sets or retrieves the eligibility criteria for capturing exceptions.
    #
    # @yieldparam exception [Exception] The exception to evaluate.
    # @return [Proc] The current eligibility proc.
    def eligible_for_capture(&block)
      if block_given?
        @eligible_for_capture = block
      else
        @eligible_for_capture ||= method(:default_eligible_for_capture)
      end
    end

    # Sets or retrieves the hook to modify binding information upon capture.
    #
    # @yieldparam binding_info [Hash] The binding information captured.
    # @return [Proc] The current on_capture hook.
    def on_capture(&block)
      if block_given?
        @on_capture_hook = block
      else
        @on_capture_hook ||= method(:default_on_capture)
      end
    end

    # Sets the on_capture hook.
    #
    # @param value [Proc] The proc to set as the on_capture hook.
    # @return [Proc] The newly set on_capture hook.
    def on_capture=(value)
      self.on_capture_hook = value
    end

    # Sets or retrieves the hook to modify formatted exception messages.
    #
    # @yieldparam formatted_string [String] The formatted exception message.
    # @return [Proc] The current on_format hook.
    def on_format(&block)
      if block_given?
        @on_format_hook = block
      else
        @on_format_hook ||= method(:default_on_format)
      end
    end

    # Sets the on_format hook.
    #
    # @param value [Proc] The proc to set as the on_format hook.
    # @return [Proc] The newly set on_format hook.
    def on_format=(value)
      @on_format_hook = value
    end

    # Formats the captured binding information into a string based on the specified format.
    #
    # @param captured_bindings [Array<Hash>] The array of captured binding information.
    # @param output_format [Symbol] The format to use (:json, :plaintext, :terminal).
    # @return [String] The formatted exception message.
    def format(captured_bindings = [], output_format = get_default_format_for_environment)
      result = binding_infos_array_to_string(captured_bindings, output_format)
      if @on_format_hook
        begin
          result = @on_format_hook.call(result)
        rescue => e
          # Since the on_format_hook failed, do not display the data
          result = ''
          # Optionally, log the error safely if logging is guaranteed not to raise exceptions
        end
      else
        result = default_on_format(result)
      end
      result
    end

    # Converts an array of binding information hashes into a formatted string.
    #
    # @param captured_bindings [Array<Hash>] The array of binding information.
    # @param format [Symbol] The format to use (:json, :plaintext, :terminal).
    # @return [String] The formatted string representation of the binding information.
    def binding_infos_array_to_string(captured_bindings, format = :terminal)
      Colors.enabled = format == :terminal
      formatted_bindings = captured_bindings.map { |binding_info| binding_info_string(binding_info) }

      format == :json ? JSON.pretty_generate(captured_bindings) : formatted_bindings.join("\n")
    end

    # Determines the default output format based on the current environment.
    #
    # @return [Symbol] The default format (:json, :plaintext, :terminal).
    def get_default_format_for_environment
      return @output_format unless @output_format.nil?
      env = ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
      @output_format = case env
                       when 'development', 'test'
                         if running_in_ci?
                           :plaintext
                         else
                           :terminal
                         end
                       when 'production'
                         :json
                       else
                         :terminal
                       end
    end

    # Checks if the code is running in a Continuous Integration (CI) environment.
    #
    # @return [Boolean] `true` if running in CI, otherwise `false`.
    def running_in_ci?
      return @running_in_ci if defined?(@running_in_ci)
      ci_env_vars = {
        'CI' => ENV['CI'],
        'JENKINS' => ENV['JENKINS'],
        'GITHUB_ACTIONS' => ENV['GITHUB_ACTIONS'],
        'CIRCLECI' => ENV['CIRCLECI'],
        'TRAVIS' => ENV['TRAVIS'],
        'APPVEYOR' => ENV['APPVEYOR'],
        'GITLAB_CI' => ENV['GITLAB_CI']
      }
      @running_in_ci = ci_env_vars.any? { |_, value| value.to_s.downcase == 'true' }
    end

    # Applies the skip list to the captured binding information, excluding specified variables.
    #
    # @param binding_info [Hash] The binding information to filter.
    # @return [Hash] The filtered binding information.
    def apply_skip_list(binding_info)
      unless @debug
        variables = binding_info[:variables]
        variables[:instances]&.reject! { |var, _| skip_list.include?(var) || (var.to_s.start_with?('@_') && !@debug) }
        variables[:locals]&.reject! { |var, _| skip_list.include?(var) }
        variables[:globals]&.reject! { |var, _| skip_list.include?(var) }
      end
      binding_info
    end

    # Validates the format of the captured binding information.
    #
    # @param binding_info [Hash] The binding information to validate.
    # @return [Hash, nil] The validated binding information or `nil` if invalid.
    def validate_binding_format(binding_info)
      unless binding_info.keys.include?(:capture_event) && binding_info[:variables].is_a?(Hash)
        # Log or handle the invalid format as needed
        return nil
      end
      binding_info
    end

    # Formats a single binding information hash into a string with colorization.
    #
    # @param binding_info [Hash] The binding information to format.
    # @return [String] The formatted string.
    def binding_info_string(binding_info)
      capture_event = safe_to_s(binding_info[:capture_event]).capitalize
      source = safe_to_s(binding_info[:source])
      result = "#{Colors.red(capture_event)}: #{Colors.blue(source)}"

      method_desc = method_and_args_desc(binding_info[:method_and_args])
      result += method_desc

      variables = binding_info[:variables] || {}

      if variables[:locals] && !variables[:locals].empty?
        result += "\n#{Colors.green('Locals:')}\n#{variable_description(variables[:locals])}"
      end

      instance_vars_to_display = variables[:instances] || {}

      if instance_vars_to_display && !instance_vars_to_display.empty?
        result += "\n#{Colors.green('Instances:')}\n#{variable_description(instance_vars_to_display)}"
      end

      if variables[:lets] && !variables[:lets].empty?
        result += "\n#{Colors.green('Let Variables:')}\n#{variable_description(variables[:lets])}"
      end

      if variables[:globals] && !variables[:globals].empty?
        result += "\n#{Colors.green('Globals:')}\n#{variable_description(variables[:globals])}"
      end

      if result.length > max_length
        result = result[0...max_length] + "... (truncated)"
      end
      result + "\n"
    rescue => e
      # Avoid raising exceptions during formatting
      return ''
    end

    private

    # Starts the TracePoint for capturing exceptions based on configured events in a specific thread.
    #
    # @param thread [Thread] The thread to start tracing in.
    # @return [void]
    def start_tracing(thread)
      return if @traces[thread]&.enabled?
      events = @capture_events ? @capture_events.to_a : default_capture_events
      trace = TracePoint.new(*events) do |tp|
        next if Thread.current[:enhanced_errors_processing] || Thread.current[:on_capture] || ignored_exception?(tp.raised_exception)
        Thread.current[:enhanced_errors_processing] = true
        exception = tp.raised_exception
        capture_me = !exception.frozen? && EnhancedErrors.eligible_for_capture.call(exception)

        unless capture_me
          Thread.current[:enhanced_errors_processing] = false
          next
        end

        binding_context = tp.binding

        unless exception.instance_variable_defined?(:@binding_infos)
          exception.instance_variable_set(:@binding_infos, [])
          exception.extend(ErrorEnhancements)
        end

        method_name = tp.method_id
        method_and_args = {
          object_name: determine_object_name(tp, method_name),
          args: extract_arguments(tp, method_name)
        }

        locals = binding_context.local_variables.map { |var|
          [var, safe_local_variable_get(binding_context, var)]
        }.to_h

        instance_vars = binding_context.receiver.instance_variables

        instances = instance_vars.map { |var|
          [var, safe_instance_variable_get(binding_context.receiver, var)]
        }.to_h

        # Extract 'let' variables from :@__memoized (RSpec specific)
        lets = {}
        if capture_let_variables && instance_vars.include?(:@__memoized)
          outer_memoized = binding_context.receiver.instance_variable_get(:@__memoized)
          memoized = outer_memoized.instance_variable_get(:@memoized) if outer_memoized.respond_to?(:instance_variable_get)
          if memoized.is_a?(Hash)
            lets = memoized&.transform_keys(&:to_sym)
          end
        end

        globals = {}
        # Capture global variables
        if @debug
          globals = (global_variables - @original_global_variables).map { |var|
            [var, get_global_variable_value(var)]
          }.to_h
        end

        capture_event = safe_to_s(tp.event)  # 'raise' or 'rescue'
        location = "#{safe_to_s(tp.path)}:#{safe_to_s(tp.lineno)}"

        binding_info = {
          source: location,
          object: tp.self,
          library: !!GEMS_REGEX.match?(location),
          method_and_args: method_and_args,
          test_name: test_name,
          variables: {
            locals: locals,
            instances: instances,
            lets: lets,
            globals: globals
          },
          exception: safe_to_s(exception.class.name),
          capture_event: capture_event
        }

        binding_info = default_on_capture(binding_info) # Apply default processing

        if on_capture_hook
          begin
            Thread.current[:on_capture] = true
            binding_info = on_capture_hook.call(binding_info)
          rescue => e
            # Since the on_capture_hook failed, do not capture this binding_info
            binding_info = nil
            # Optionally, log the error safely if logging is guaranteed not to raise exceptions
          ensure
            Thread.current[:on_capture] = false
          end
        end

        # Proceed only if binding_info is valid
        if binding_info
          binding_info = validate_binding_format(binding_info)
          if binding_info
            exception.instance_variable_get(:@binding_infos) << binding_info
          end
        end
      rescue => e
        # Avoid any code here that could raise exceptions
      ensure
        Thread.current[:enhanced_errors_processing] = false
      end

      @traces[thread] = trace
      trace.enable
    end

    # Overrides Thread.new and Thread.start to ensure TracePoint is enabled in new threads.
    #
    # @return [void]
    def override_thread_new
      return if @thread_overridden
      @thread_overridden = true

      class << Thread
        alias_method :original_new, :new

        def new(*args, &block)
          original_new(*args) do |*block_args|
            EnhancedErrors.send(:start_tracing, Thread.current)
            block.call(*block_args)
          end
        end

        alias_method :original_start, :start

        def start(*args, &block)
          original_start(*args) do |*block_args|
            EnhancedErrors.send(:start_tracing, Thread.current)
            block.call(*block_args)
          end
        end
      end
    end

    # Checks if the exception is in the ignored exceptions list.
    #
    # @param exception [Exception] The exception to check.
    # @return [Boolean] `true` if the exception should be ignored, otherwise `false`.
    def ignored_exception?(exception)
      IGNORED_EXCEPTIONS.any? { |klass| exception.is_a?(klass) }
    end

    # Retrieves the current test name from RSpec, if available.
    #
    # @return [String, nil] The current test name or `nil` if not in a test context.
    def test_name
      if defined?(RSpec)
        RSpec&.current_example&.full_description
      end
    rescue
      nil
    end

    # Helper method to determine the default capture types based on Ruby version
    #
    # @return [Set<Symbol>] The default set of capture types
    def default_capture_events
      events = [:raise]
      if capture_rescue && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0')
        events << :rescue
      end
      Set.new(events)
    end

    # Validates and sets the capture events for TracePoint.
    #
    # @param capture_events [Array<Symbol>, nil] The events to capture.
    # @return [void]
    def validate_and_set_capture_events(capture_events)
      if capture_events.nil?
        @capture_events = default_capture_events
        return
      end

      unless valid_capture_events?(capture_events)
        puts "EnhancedErrors: Invalid capture_events provided. Falling back to defaults."
        @capture_events = default_capture_events
        return
      end

      if capture_events.include?(:rescue) && Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.3.0')
        puts "EnhancedErrors: Warning: :rescue capture_event is not supported in Ruby versions below 3.3.0 and will be ignored."
        capture_events = capture_events - [:rescue]
      end

      if capture_events.empty?
        puts "No valid capture_events provided to EnhancedErrors.enhance! Falling back to defaults."
        @capture_events = default_capture_events
        return
      end

      @capture_events = capture_events.to_set
    end

    # Validates the capture events.
    #
    # @param capture_events [Array<Symbol>] The events to validate.
    # @return [Boolean] `true` if valid, otherwise `false`.
    def valid_capture_events?(capture_events)
      return false unless capture_events.is_a?(Array) || capture_events.is_a?(Set)
      valid_types = [:raise, :rescue].to_set
      capture_events.to_set.subset?(valid_types)
    end

    # Extracts method arguments from the TracePoint binding.
    #
    # @param tp [TracePoint] The current TracePoint.
    # @param method_name [Symbol] The name of the method.
    # @return [String] A string representation of the method arguments.
    def extract_arguments(tp, method_name)
      return '' unless method_name
      begin
        bind = tp.binding
        unbound_method = tp.defined_class.instance_method(method_name)
        method_obj = unbound_method.bind(tp.self)
        parameters = method_obj.parameters
        locals = bind.local_variables

        parameters.map do |(type, name)|
          value = locals.include?(name) ? safe_local_variable_get(bind, name) : nil
          "#{name}=#{safe_inspect(value)}"
        rescue => e
          "#{name}=#<Error getting argument: #{e.message}>"
        end.join(", ")
      rescue => e
        "#<Error getting arguments: #{e.message}>"
      end
    end

    # Determines the object name based on the TracePoint and method name.
    #
    # @param tp [TracePoint] The current TracePoint.
    # @param method_name [Symbol] The name of the method.
    # @return [String] The formatted object name.
    def determine_object_name(tp, method_name)
      if tp.self.is_a?(Class) && tp.self.singleton_class == tp.defined_class
        "#{safe_to_s(tp.self)}.#{method_name}"
      else
        "#{safe_to_s(tp.self.class.name)}##{method_name}"
      end
    rescue => e
      "#<Error inspecting value: #{e.message}>"
    end

    # Retrieves the value of a global variable by its name.
    #
    # @param var [Symbol] The name of the global variable.
    # @return [Object, String] The value of the global variable or an error message.
    def get_global_variable_value(var)
      begin
        var.is_a?(Symbol) ? eval("#{var}") : nil
      rescue => e
        "#<Error getting value for #{var}>"
      end
    end

    # Generates a description for method and arguments.
    #
    # @param method_info [Hash] Information about the method and its arguments.
    # @return [String] The formatted description.
    def method_and_args_desc(method_info)
      object_name = safe_to_s(method_info[:object_name])
      args = safe_to_s(method_info[:args])
      return '' if object_name.empty? && args.empty?
      arg_str = args.empty? ? '' : "(#{args})"
      str = object_name + arg_str
      "\n#{Colors.green('Method: ')}#{Colors.blue(str)}\n"
    rescue => e
      ''
    end

    # Generates a formatted description for a set of variables.
    #
    # @param vars_hash [Hash] A hash of variable names and their values.
    # @return [String] The formatted variables description.
    def variable_description(vars_hash)
      vars_hash.map do |name, value|
        "  #{Colors.purple(name)}: #{format_variable(value)}\n"
      end.join
    rescue => e
      ''
    end

    # Formats a variable for display, using `awesome_print` if available and enabled.
    #
    # @param variable [Object] The variable to format.
    # @return [String] The formatted variable.
    def format_variable(variable)
      if awesome_print_available? && Colors.enabled?
        variable.ai
      else
        safe_inspect(variable)
      end
    rescue => e
      var_str = safe_to_s(variable)
      "#{var_str}: [Inspection Error]"
    end

    # Checks if the `AwesomePrint` gem is available.
    #
    # @return [Boolean] `true` if `AwesomePrint` is available, otherwise `false`.
    def awesome_print_available?
      return @awesome_print_available unless @awesome_print_available.nil?
      @awesome_print_available = defined?(AwesomePrint)
    end

    # Safely calls `inspect` on a variable.
    #
    # @param variable [Object] The variable to inspect.
    # @return [String] The inspected variable or a safe fallback.
    def safe_inspect(variable)
      variable.inspect
    rescue => e
      safe_to_s(variable)
    end

    # Safely converts a variable to a string, handling exceptions.
    #
    # @param variable [Object] The variable to convert.
    # @return [String] The string representation or a safe fallback.
    def safe_to_s(variable)
      str = variable.to_s
      if str.length > 120
        str[0...120] + '...'
      else
        str
      end
    rescue
      "[Unprintable variable]"
    end

    # Safely retrieves a local variable from a binding.
    #
    # @param binding_context [Binding] The binding context.
    # @param var_name [Symbol] The name of the local variable.
    # @return [Object] The value of the local variable or a safe fallback.
    def safe_local_variable_get(binding_context, var_name)
      binding_context.local_variable_get(var_name)
    rescue
      "[Error accessing local variable #{var_name}]"
    end

    # Safely retrieves an instance variable from an object.
    #
    # @param obj [Object] The object.
    # @param var_name [Symbol] The name of the instance variable.
    # @return [Object] The value of the instance variable or a safe fallback.
    def safe_instance_variable_get(obj, var_name)
      obj.instance_variable_get(var_name)
    rescue
      "[Error accessing instance variable #{var_name}]"
    end

    # Default implementation for the on_format hook.
    #
    # @param string [String] The formatted exception message.
    # @return [String] The unmodified exception message.
    def default_on_format(string)
      string
    end

    # Default implementation for the on_capture hook, applying the skip list.
    #
    # @param binding_info [Hash] The captured binding information.
    # @return [Hash] The filtered binding information.
    def default_on_capture(binding_info)
      # Use this to clean up the captured bindings
      EnhancedErrors.apply_skip_list(binding_info)
    end

    # Default eligibility check for capturing exceptions.
    #
    # @param exception [Exception] The exception to evaluate.
    # @return [Boolean] `true` if the exception should be captured, otherwise `false`.
    def default_eligible_for_capture(exception)
      true
    end

    @enabled = false
  end
end
