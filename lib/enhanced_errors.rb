require 'set'
require 'json'

require_relative 'colors'
require_relative 'error_enhancements'
require_relative 'binding'


class EnhancedErrors
  class << self
    attr_accessor :enabled, :trace, :config_block, :max_length, :on_capture_hook, :capture_let_variables,
                  :eligible_for_capture, :skip_list

    GEMS_REGEX = %r{[\/\\]gems[\/\\]}
    DEFAULT_MAX_LENGTH = 2500

    RSPEC_SKIP_LIST = Set.new([
                                :@fixture_cache,
                                :@fixture_cache_key,
                                :@fixture_connection_pools,
                                :@connection_subscriber,
                                :@saved_pool_configs,
                                :@loaded_fixtures,
                                :@matcher_definitions
                              ])

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


    def max_length(value = nil)
      if value.nil?
        @max_length ||= DEFAULT_MAX_LENGTH
      else
        @max_length = value
      end
      @max_length
    end

    def capture_let_variables(value = nil)
      if value.nil?
        @capture_let_variables = @capture_let_variables.nil? ? true : @capture_let_variables
      else
        @capture_let_variables = value
      end
    end

    def skip_list
      @skip_list ||= default_skip_list
    end

    # We add the names of all global variables to the skip list when we initialize by default.
    # This is because global variables can be very large and are not typically useful for debugging.
    def default_skip_list
      Set.new(RAILS_SKIP_LIST).merge(RSPEC_SKIP_LIST)
    end

    def add_to_skip_list(*vars)
      skip_list.merge(vars)
    end

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

    def eligible_for_capture(&block)
      if block_given?
        @eligible_for_capture = block
      else
        @eligible_for_capture ||= method(:default_eligible_for_capture)
      end
    end

    def on_capture(&block)
      if block_given?
        @on_capture_hook = block
      else
        @on_capture_hook ||= method(:default_on_capture)
      end
    end

    def on_capture=(value)
      self.on_capture_hook = value
    end

    # Publicly exposed format method
    def format(captured_bindings = [], output_format = get_default_format_for_environment)
      binding_infos_array_to_string(captured_bindings, output_format)
    end

    # Convert an array of binding_infos into a string based on the format
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

    # Determine the default format based on the environment
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

    def running_in_ci?
      return @running_in_ci if defined?(@running_in_ci)
      ci_env_vars = {
        'CI' => ENV['CI'],
        'GITHUB_ACTIONS' => ENV['GITHUB_ACTIONS'],
        'CIRCLECI' => ENV['CIRCLECI'],
        'TRAVIS' => ENV['TRAVIS'],
        'APPVEYOR' => ENV['APPVEYOR'],
        'GITLAB_CI' => ENV['GITLAB_CI']
      }
      @running_in_ci =  ci_env_vars.any? { |_, value| value.to_s.downcase == 'true' }
    end

    # Expose apply_skip_list
    def apply_skip_list(binding_info)
      unless @debug
        variables = binding_info[:variables]
        variables[:instances]&.reject! { |var, _| skip_list.include?(var) }
        variables[:locals]&.reject! { |var, _| skip_list.include?(var) }
        variables[:globals]&.reject! { |var, _| skip_list.include?(var) }
      end
      binding_info
    end

    # Validate the format of binding_info
    def validate_binding_format(binding_info)
      unless binding_info.keys.include?(:capture_type) && binding_info[:variables].is_a?(Hash)
        puts "Invalid binding_info format."
        return nil
      end
      binding_info
    end

    private

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

        globals = { }
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

    # Helper methods
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

    def determine_object_name(tp, method_name)
      if tp.self.is_a?(Class) && tp.self.singleton_class == tp.defined_class
        "#{tp.self}.#{method_name}"
      else
        "#{tp.defined_class}##{method_name}"
      end
    rescue => e
      "#<Error inspecting value: #{e.message}>"
    end

    # Retrieve the value of a global variable by name.
    def get_global_variable_value(var)
      begin
        var.is_a?(Symbol) ? eval("#{var}") : nil
      rescue => e
        "#<Error getting value: #{e.message}>"
      end
    end

    def binding_info_string(binding_info)
      result = "\n#{Colors.green('Source: ')}#{Colors.blue(binding_info[:source])}"
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

    def method_and_args_desc(method_info)
      return '' unless method_info[:object_name] != '' || method_info[:args]&.length.to_i > 0
      str = method_info[:object_name] + "(#{method_info[:args]})"

      "\n#{Colors.green('Method: ')}#{Colors.blue(str)}\n"
    end

    def variable_description(vars_hash)
      vars_hash.map do |name, value|
        "  #{Colors.purple(name)}: #{format_variable(value)}\n"
      end.join
    end

    def format_variable(variable)
      (awesome_print_available? && Colors.enabled?) ? variable.ai : variable.inspect
    end

    def awesome_print_available?
      return @awesome_print_available unless @awesome_print_available.nil?
      @awesome_print_available = defined?(AwesomePrint)
    end

    def default_on_capture(binding_info)
      # Use this to clean up the captured bindings
      EnhancedErrors.apply_skip_list(binding_info)
    end

    def default_eligible_for_capture(exception)
      true
    end

    @enabled = false
  end
end
