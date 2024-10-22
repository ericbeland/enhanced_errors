require 'set'
require 'json'

require_relative 'colors'
require_relative 'error_enhancements'
require_relative 'binding'

# The EnhancedErrors class provides mechanisms to enhance exception handling by capturing
# additional context such as binding information, variables, and method arguments when exceptions are raised.
# It offers customization options for formatting and filtering captured data.
class EnhancedErrors
  class << self
    # @!attribute [rw] enabled
    #   @return [Boolean] Indicates whether EnhancedErrors is enabled.
    attr_accessor :enabled

    # @!attribute [rw] trace
    #   @return [TracePoint, nil] The TracePoint object used for tracing exceptions.
    attr_accessor :trace

    # @!attribute [rw] config_block
    #   @return [Proc, nil] The configuration block provided during enhancement.
    attr_accessor :config_block

    # @!attribute [rw] max_length
    #   @return [Integer] The maximum length of the formatted exception message.
    attr_accessor :max_length

    # @!attribute [rw] on_capture_hook
    #   @return [Proc, nil] Hook to modify binding information upon capture.
    attr_accessor :on_capture_hook

    # @!attribute [rw] capture_let_variables
    #   @return [Boolean] Determines whether RSpec `let` variables are captured.
    attr_accessor :capture_let_variables

    # @!attribute [rw] eligible_for_capture
    #   @return [Proc, nil] A proc that determines if an exception is eligible for capture.
    attr_accessor :eligible_for_capture

    # @!attribute [rw] skip_list
    #   @return [Set<Symbol>] A set of variable names to exclude from binding information.
    attr_accessor :skip_list

    # @!constant GEMS_REGEX
    #   @return [Regexp] Regular expression to identify gem paths.
    GEMS_REGEX = %r{[\/\\]gems[\/\\]}

    # @!constant DEFAULT_MAX_LENGTH
    #   @return [Integer] The default maximum length for formatted exception messages.
    DEFAULT_MAX_LENGTH = 2500

    # @!constant RSPEC_SKIP_LIST
    #   @return [Set<Symbol>] A set of RSpec-specific instance variables to skip.
    RSPEC_SKIP_LIST = Set.new([
                                :@fixture_cache,
                                :@fixture_cache_key,
                                :@fixture_connection_pools,
                                :@connection_subscriber,
                                :@saved_pool_configs,
                                :@loaded_fixtures,
                                :@matcher_definitions
                              ])

    # @!constant RAILS_SKIP_LIST
    #   @return [Set<Symbol>] A set of Rails-specific instance variables to skip.
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
                                :@mutations_from_database
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
    def enhance!(enabled: true, debug: false, **options, &block)
      @output_format = nil
      @eligible_for_capture = nil
      @original_global_variables = nil
      if enabled == false
        @original_global_variables = nil
        @enabled = false
        @trace.disable if @trace
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

        start_tracing
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
    # @param output_format [Symbol] The format to use for output (:json, :plaintext, :terminal).
    # @return [String] The formatted exception message.
    def format(captured_bindings = [], output_format = get_default_format_for_environment)
      result = binding_infos_array_to_string(captured_bindings, output_format)
      if @on_format_hook
        result = @on_format_hook.call(result)
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
      case format
      when :json
        Colors.enabled = false
        JSON.pretty_generate(captured_bindings)
      when :plaintext
        Colors.enabled = false
        captured_bindings.map { |binding_info| binding_info_string(binding_info) }.join("\n")
      when :terminal
        Colors.enabled = true
        captured_bindings.map { |binding_info| binding_info_string(binding_info) }.join("\n")
      else
        Colors.enabled = false
        captured_bindings.map { |binding_info| binding_info_string(binding_info) }.join("\n")
      end
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
        variables[:instances]&.reject! { |var, _| skip_list.include?(var) }
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
      unless binding_info.keys.include?(:capture_type) && binding_info[:variables].is_a?(Hash)
        puts "Invalid binding_info format."
        return nil
      end
      binding_info
    end

    # Formats a single binding information hash into a string with colorization.
    #
    # @param binding_info [Hash] The binding information to format.
    # @return [String] The formatted string.
    def binding_info_string(binding_info)
      result = "\n#{Colors.green("#{binding_info[:capture_type].capitalize}: ")}#{Colors.blue(binding_info[:source])}"
      result += method_and_args_desc(binding_info[:method_and_args])

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
      result + "\n\n"
    end

    # Generates a description string for method and its arguments.
    #
    # @param method_info [Hash] Information about the method and its arguments.
    # @return [String] The method and arguments description.
    def method_and_args_desc(method_info)
      return '' unless method_info[:object_name] != '' || method_info[:args]&.length.to_i > 0
      str = method_info[:object_name] + "(#{method_info[:args]})"

      "\n#{Colors.green('Method: ')}#{Colors.blue(str)}\n"
    end

    # Generates a formatted description for a set of variables.
    #
    # @param vars_hash [Hash] A hash of variable names and their values.
    # @return [String] The formatted variables description.
    def variable_description(vars_hash)
      vars_hash.map do |name, value|
        "  #{Colors.purple(name)}: #{format_variable(value)}\n"
      end.join
    end

    # Formats a variable for display, using `awesome_print` if available and enabled.
    #
    # @param variable [Object] The variable to format.
    # @return [String] The formatted variable.
    def format_variable(variable)
      (awesome_print_available? && Colors.enabled?) ? variable.ai : variable.inspect
    end

    # Checks if the `AwesomePrint` gem is available.
    #
    # @return [Boolean] `true` if `AwesomePrint` is available, otherwise `false`.
    def awesome_print_available?
      return @awesome_print_available unless @awesome_print_available.nil?
      @awesome_print_available = defined?(AwesomePrint)
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

    private

    # Starts the TracePoint for capturing exceptions based on configured events.
    #
    # @return [void]
    def start_tracing
      return if @trace && @trace.enabled?

      events = [:raise]
      events << :rescue if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0')

      @trace = TracePoint.new(*events) do |tp|
        exception = tp.raised_exception
        capture_me = EnhancedErrors.eligible_for_capture.call(exception)

        next unless capture_me

        next if Thread.current[:enhanced_errors_processing]
        Thread.current[:enhanced_errors_processing] = true

        exception = tp.raised_exception
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
          [var, binding_context.local_variable_get(var)]
        }.to_h

        instance_vars = tp.self.instance_variables

        instances = instance_vars.map { |var|
          [var, (tp.self.instance_variable_get(var) rescue "#<Error getting instance variable: #{$!.message}>")]
        }.to_h

        # Extract 'let' variables from :@__memoized (RSpec specific)
        lets = {}
        if @capture_let_variables && tp.self.instance_variable_defined?(:@__memoized)
          outer_memoized = tp.self&.instance_variable_get(:@__memoized)
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
          puts "Global Variables: #{globals.inspect}"
        end

        capture_type = tp.event.to_s  # 'raise' or 'rescue'
        location = "#{tp.path}:#{tp.lineno}"

        binding_info = {
          source: location,
          object: tp.self,
          library: !!GEMS_REGEX.match?(location),
          method_and_args: method_and_args,
          variables: {
            locals: locals,
            instances: instances,
            lets: lets,
            globals: globals
          },
          exception: exception.class.name,
          capture_type: capture_type
        }

        if on_capture_hook
          binding_info = on_capture_hook.call(binding_info)
        else
          binding_info = default_on_capture(binding_info)
        end

        binding_info = validate_binding_format(binding_info)

        if binding_info
          exception.instance_variable_get(:@binding_infos) << binding_info
        else
          puts "Invalid binding_info returned from on_capture, skipping."
        end
      ensure
        Thread.current[:enhanced_errors_processing] = false
      end

      @trace.enable
    end

    # Extracts method arguments from the TracePoint binding.
    #
    # @param tp [TracePoint] The current TracePoint.
    # @param method_name [Symbol] The name of the method.
    # @return [String] A string representation of the method arguments.
    def extract_arguments(tp, method_name)
      binding = tp.binding
      method = method_name
      return '' unless method

      locals = binding.local_variables

      return binding.receiver.method(method).parameters.map do |(type, name)|
        value = locals.include?(name) ? binding.local_variable_get(name) : nil
        "#{name}=#{value.inspect}"
      rescue => e
        "#{name}=#<Error getting argument: #{e.message}>"
      end.join(", ")
    rescue => e
      "#<Error getting arguments: #{e.message}>"
    end

    # Determines the object name based on the TracePoint and method name.
    #
    # @param tp [TracePoint] The current TracePoint.
    # @param method_name [Symbol] The name of the method.
    # @return [String] The formatted object name.
    def determine_object_name(tp, method_name)
      if tp.self.is_a?(Class) && tp.self.singleton_class == tp.defined_class
        "#{tp.self}.#{method_name}"
      else
        "#{tp.defined_class}##{method_name}"
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
        "#<Error getting value: #{e.message}>"
      end
    end

    # Generates a description for method and arguments.
    #
    # @param method_info [Hash] Information about the method and its arguments.
    # @return [String] The formatted description.
    def method_and_args_desc(method_info)
      return '' unless method_info[:object_name] != '' || method_info[:args]&.length.to_i > 0
      str = method_info[:object_name] + "(#{method_info[:args]})"

      "\n#{Colors.green('Method: ')}#{Colors.blue(str)}\n"
    end

    # Generates a formatted description for a set of variables.
    #
    # @param vars_hash [Hash] A hash of variable names and their values.
    # @return [String] The formatted variables description.
    def variable_description(vars_hash)
      vars_hash.map do |name, value|
        "  #{Colors.purple(name)}: #{format_variable(value)}\n"
      end.join
    end

    # Formats a variable for display, using `awesome_print` if available and enabled.
    #
    # @param variable [Object] The variable to format.
    # @return [String] The formatted variable.
    def format_variable(variable)
      (awesome_print_available? && Colors.enabled?) ? variable.ai : variable.inspect
    end

    # Checks if the `AwesomePrint` gem is available.
    #
    # @return [Boolean] `true` if `AwesomePrint` is available, otherwise `false`.
    def awesome_print_available?
      return @awesome_print_available unless @awesome_print_available.nil?
      @awesome_print_available = defined?(AwesomePrint)
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
