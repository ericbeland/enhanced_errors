# enhanced_errors.rb

require 'set'
require 'json'
require 'monitor'

require_relative 'enhanced/colors'
require_relative 'enhanced/exception'

IGNORED_EXCEPTIONS = %w[SystemExit NoMemoryError SignalException Interrupt
 ScriptError LoadError NotImplementedError SyntaxError
 RSpec::Expectations::ExpectationNotMetError
 RSpec::Matchers::BuiltIn::RaiseError
 SystemStackError Psych::BadAlias]

class EnhancedErrors
  extend ::Enhanced

  class << self
    def mutex
      @monitor ||= Monitor.new
    end

    attr_accessor :enabled, :config_block, :on_capture_hook, :eligible_for_capture, :trace, :override_messages

    GEMS_REGEX = %r{[\/\\]gems[\/\\]}
    RSPEC_EXAMPLE_REGEXP = /RSpec::ExampleGroups::[A-Z0-9]+.*/
    DEFAULT_MAX_LENGTH = 2000
    MAX_BINDING_INFOS = 3

    RSPEC_SKIP_LIST = [
                                :@__inspect_output,
                                :@__memoized,
                                :@assertion_delegator,
                                :@assertion_instance,
                                :@assertions,
                                :@connection_subscriber,
                                :@example,
                                :@fixture_cache,
                                :@fixture_cache_key,
                                :@fixture_connection_pools,
                                :@fixture_connections,
                                :@integration_session,
                                :@legacy_saved_pool_configs,
                                :@loaded_fixtures,
                                :@matcher_definitions,
                                :@saved_pool_configs
                              ].freeze

    RAILS_SKIP_LIST = [
                                :@new_record,
                                :@attributes,
                                :@association_cache,
                                :@readonly,
                                :@previously_new_record,
                                :@_routes,
                                :@routes,
                                :@app,
                                :@arel_table,
                                :@assertion_instance,
                                :@association_cache,
                                :@attributes,
                                :@destroyed,
                                :@destroyed_by_association,
                                :@find_by_statement_cache,
                                :@generated_relation_method,
                                :@integration_session,
                                :@marked_for_destruction,
                                :@mutations_before_last_save,
                                :@mutations_from_database,
                                :@new_record,
                                :@predicate_builder,
                                :@previously_new_record,
                                :@primary_key,
                                :@readonly,
                                :@relation_delegate_cache,
                                :@response,
                                :@response_klass,
                                :@routes,
                                :@strict_loading,
                                :@strict_loading_mode
                              ].freeze

    MINITEST_SKIP_LIST = [:@NAME, :@failures, :@time].freeze

    DEFAULT_SKIP_LIST = (RAILS_SKIP_LIST + RSPEC_SKIP_LIST + MINITEST_SKIP_LIST)

    RSPEC_HANDLER_NAMES = ['RSpec::Expectations::PositiveExpectationHandler', 'RSpec::Expectations::NegativeExpectationHandler']

    @enabled = false
    @max_length = nil
    @capture_rescue = nil
    @skip_list = nil
    @capture_events = nil
    @debug = nil
    @output_format = nil
    @eligible_for_capture = nil
    @original_global_variables = nil
    @trace = nil
    @override_messages = nil
    @rspec_failure_message_loaded = nil

    # Default values
    @max_capture_events = -1   # -1 means no limit
    @capture_events_count = 0

    # Thread-safe getters and setters
    def enabled=(val)
      mutex.synchronize { @enabled = val }
    end

    def enabled
      mutex.synchronize { @enabled }
    end

    def capture_rescue=(val)
      mutex.synchronize { @capture_rescue = val }
    end

    def capture_rescue
      mutex.synchronize {  @capture_rescue }
    end

    def capture_events_count
      mutex.synchronize { @capture_events_count }
    end

    def capture_events_count=(val)
      mutex.synchronize { @capture_events_count = val }
    end

    def max_capture_events
      mutex.synchronize { @max_capture_events }
    end

    def max_capture_events=(value)
      mutex.synchronize do
        @max_capture_events = value
        if @max_capture_events == 0
          # Disable capturing
          if @enabled
            puts "EnhancedErrors: max_capture_events set to 0, disabling capturing."
            @enabled = false
            @trace&.disable
            @rspec_tracepoint&.disable
            @minitest_trace&.disable
          end
        end
      end
    end

    def increment_capture_events_count
      mutex.synchronize do
        @capture_events_count ||= 0
        @max_capture_events ||= -1
        @capture_events_count += 1
        # Check if we've hit the limit
        if @max_capture_events > 0 && @capture_events_count >= @max_capture_events
          # puts "EnhancedErrors: max_capture_events limit (#{@max_capture_events}) reached, disabling capturing."
          @enabled = false
        end
      end
    end

    def reset_capture_events_count
      mutex.synchronize do
        @capture_events_count = 0
        @enabled = true
        @rspec_tracepoint.enable if @rspec_tracepoint
        @trace.enable if @trace
      end
    end

    def max_length(value = nil)
      mutex.synchronize do
        if value.nil?
          @max_length ||= DEFAULT_MAX_LENGTH
        else
          @max_length = value
        end
        @max_length
      end
    end

    def skip_list
      mutex.synchronize do
        @skip_list ||= DEFAULT_SKIP_LIST
      end
    end

    def override_rspec_message(example, binding_or_bindings)
      exception_obj = example.exception
      case exception_obj
      when nil
        return nil
      when RSpec::Core::MultipleExceptionError
        override_exception_message(exception_obj.all_exceptions.first, binding_or_bindings)
      else
        override_exception_message(exception_obj, binding_or_bindings)
      end

    end

    def override_exception_message(exception, binding_or_bindings)
      return nil unless exception
      rspec_binding = !(binding_or_bindings.nil? || binding_or_bindings.empty?)
      exception_binding = (exception.binding_infos.length > 0)
      has_message = !(exception.respond_to?(:unaltered_message))
      return nil unless (rspec_binding || exception_binding) && has_message

      variable_str = EnhancedErrors.format(binding_or_bindings)
      message_str = exception.message
      if exception.respond_to?(:captured_variables) && !message_str.include?(exception.captured_variables)
        message_str += exception.captured_variables
      end
      exception.define_singleton_method(:unaltered_message) { message_str }
      exception.define_singleton_method(:message) do
        "#{message_str}#{variable_str}"
      end
      exception
    end

    def add_to_skip_list(*vars)
      mutex.synchronize do
        @skip_list.concat(vars)
      end
    end

    def enhance_exceptions!(enabled: true, debug: false, capture_events: nil, override_messages: false, **options, &block)
      mutex.synchronize do
        @trace&.disable
        @trace = nil

        @output_format = nil
        @eligible_for_capture = nil
        @original_global_variables = nil
        @override_messages = override_messages

        # Ensure these are not nil
        @max_capture_events = -1 if @max_capture_events.nil?
        @capture_events_count = 0

        @rspec_failure_message_loaded = true

        if !enabled
          @original_global_variables = nil
          @enabled = false
          return
        end

        @enabled = true
        @debug = debug
        @original_global_variables = global_variables if @debug

        options.each do |key, value|
          setter_method = "#{key}="
          if respond_to?(setter_method)
            send(setter_method, value)
          elsif respond_to?(key)
            send(key, value)
          end
        end

        @config_block = block_given? ? block : nil
        instance_eval(&@config_block) if @config_block

        validate_and_set_capture_events(capture_events)

        # If max_capture_events == 0, capturing is off from the start.
        if @max_capture_events == 0
          @enabled = false
          return
        end

        events = @capture_events ? @capture_events.to_a : default_capture_events
        @trace = TracePoint.new(*events) do |tp|
          handle_tracepoint_event(tp)
        end

        # Only enable trace if still enabled and not limited
        if @enabled && (@max_capture_events == -1 || @capture_events_count < @max_capture_events)
          @trace.enable
        end
      end
    end

    def safe_prepend_module(target_class, mod)
      mutex.synchronize do
        if defined?(target_class) && target_class.is_a?(Module)
          target_class.prepend(mod)
          true
        else
          false
        end
      end
    end

    def safely_prepend_rspec_custom_failure_message
      mutex.synchronize do
        return if @rspec_failure_message_loaded
        if defined?(RSpec::Core::Example) && !RSpec::Core::Example < Enhanced::Integrations::RSpecErrorFailureMessage
          RSpec::Core::Example.prepend(Enhanced::Integrations::RSpecErrorFailureMessage)
          @rspec_failure_message_loaded = true
        end
      end
    rescue => e
      puts "Failed to prepend RSpec custom failure message: #{e.message}"
    end

    def is_a_minitest?(klass)
      klass.ancestors.include?(Minitest::Test) && klass.name != 'Minitest::Test'
    end

    def start_minitest_binding_capture
      mutex.synchronize do
        @minitest_trace = TracePoint.new(:return) do |tp|
          next unless tp.method_id.to_s.start_with?('test_') && is_a_minitest?(tp.defined_class)
          @minitest_test_binding = tp.binding
        end
        @minitest_trace.enable
      end
    end

    def stop_minitest_binding_capture
      mutex.synchronize do
        @minitest_trace&.disable
        @minitest_trace = nil
        convert_binding_to_binding_info(@minitest_test_binding) if @minitest_test_binding
      end
    end

    def class_to_string(klass)
      return '' if klass.nil?
      if klass.singleton_class?
        klass.to_s.match(/#<Class:(.*?)>/)[1]
      else
        klass.to_s
      end
    end

    def is_rspec_example?(tracepoint)
      tracepoint.method_id.nil?  && !(tracepoint.path.include?('rspec')) && tracepoint.path.end_with?('_spec.rb')
    end

    def start_rspec_binding_capture
      mutex.synchronize do
        @rspec_example_binding = nil
        @capture_next_binding = false
        @rspec_tracepoint&.disable
        @enabled = true if @enabled.nil?

        @rspec_tracepoint = TracePoint.new(:raise, :b_return) do |tp|
          # puts "name #{tp.raised_exception.class.name rescue ''} method:#{tp.method_id} tp.binding:#{tp.binding.local_variables rescue ''}"
          # puts "event: #{tp.event} defined_class#{class_to_string(tp.defined_class)} #{tp.path}:#{tp.lineno} #{tp.callee_id} "
          # This trickery below is to help us identify the anonymous block return we want to grab
          # Very kluge-y and edge cases have grown it, but it works
          if tp.event == :b_return
            if RSPEC_HANDLER_NAMES.include?(class_to_string(tp.defined_class))
              @capture_next_binding = :next
              next
            end
            next unless @capture_next_binding

            if @capture_next_binding == :next || @capture_next_binding == :next_matching && is_rspec_example?(tp)
              increment_capture_events_count
              @capture_next_binding = false
              @rspec_example_binding = tp.binding
            end
          elsif tp.event == :raise
            class_name = tp.raised_exception.class.name
            case class_name
            when 'RSpec::Expectations::ExpectationNotMetError'
              @capture_next_binding = :next_matching
            else
              handle_tracepoint_event(tp)
            end
          end
        end
        @rspec_tracepoint.enable
      end
    end

    def stop_rspec_binding_capture
      mutex.synchronize do
        @rspec_tracepoint&.disable
        @rspec_tracepoint = nil
        binding_info = convert_binding_to_binding_info(@rspec_example_binding) if @rspec_example_binding
        @capture_next_binding = false
        @rspec_example_binding = nil
        binding_info
      end
    end

    def convert_binding_to_binding_info(b, capture_let_variables: true)
      file = b.eval("__FILE__") rescue nil
      line = b.eval("__LINE__") rescue nil
      location = [file, line].compact.join(":")

      locals = b.local_variables.map { |var| [var, safe_local_variable_get(b, var)] }.to_h
      receiver = b.receiver
      instance_vars = receiver.instance_variables
      instances = instance_vars.map { |var| [var, safe_instance_variable_get(receiver, var)] }.to_h

      lets = {}
      if capture_let_variables && instance_vars.include?(:@__memoized)
        outer_memoized = receiver.instance_variable_get(:@__memoized)
        memoized = outer_memoized.instance_variable_get(:@memoized) if outer_memoized.respond_to?(:instance_variable_get)
        if memoized.is_a?(Hash)
          lets = memoized.transform_keys(&:to_sym)
        end
      end

      binding_info = {
        source: location,
        object: receiver,
        library: !!GEMS_REGEX.match?(location.to_s),
        method_and_args: {
          object_name: '',
          args: ''
        },
        test_name: test_name,
        variables: {
          locals: locals,
          instances: instances,
          lets: lets,
          globals: {}
        },
        exception: 'NoException',
        capture_event: 'RSpecContext'
      }

      default_on_capture(binding_info)
    end

    def eligible_for_capture(&block)
      mutex.synchronize do
        if block_given?
          @eligible_for_capture = block
        else
          @eligible_for_capture ||= method(:default_eligible_for_capture)
        end
      end
    end

    def on_capture(&block)
      mutex.synchronize do
        if block_given?
          @on_capture_hook = block
        else
          @on_capture_hook ||= method(:default_on_capture)
        end
      end
    end

    def on_capture=(value)
      mutex.synchronize do
        @on_capture_hook = value
      end
    end

    def on_format(&block)
      mutex.synchronize do
        if block_given?
          @on_format_hook = block
        else
          @on_format_hook ||= method(:default_on_format)
        end
      end
    end

    def on_format=(value)
      mutex.synchronize do
        @on_format_hook = value
      end
    end

    def format(captured_binding_infos = [], output_format = get_default_format_for_environment)
      return '' if captured_binding_infos.nil? || captured_binding_infos.empty?

      result = binding_infos_array_to_string(captured_binding_infos, output_format)

      mutex.synchronize do
        if @on_format_hook
          begin
            result = @on_format_hook.call(result)
          rescue
            result = ''
          end
        else
          result = default_on_format(result)
        end
      end

      result
    end

    def binding_infos_array_to_string(captured_bindings, format = :terminal)
      return '' if captured_bindings.nil? || captured_bindings.empty?
      captured_bindings = [captured_bindings] unless captured_bindings.is_a?(Array)
      Colors.enabled = (format == :terminal)
      formatted_bindings = captured_bindings.to_a.map { |binding_info| binding_info_string(binding_info) }
      format == :json ? JSON.pretty_generate(captured_bindings) : "\n#{formatted_bindings.join("\n")}"
    end

    def get_default_format_for_environment
      mutex.synchronize do
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
    end

    def running_in_ci?
      mutex.synchronize do
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
    end

    def apply_skip_list(binding_info)
      mutex.synchronize do
        variables = binding_info[:variables]
        variables[:instances]&.reject! { |var, _| skip_list.include?(var) || (var.to_s.start_with?('@_') && !@debug) }
        variables[:locals]&.reject! { |var, _| skip_list.include?(var) }
        if @debug
          variables[:globals]&.reject! { |var, _| skip_list.include?(var) }
        end
      end
      binding_info
    end

    def validate_binding_format(binding_info)
      unless binding_info.keys.include?(:capture_event) && binding_info[:variables].is_a?(Hash)
        return nil
      end
      binding_info
    end

    def binding_info_string(binding_info)
      exception = safe_to_s(binding_info[:exception])
      capture_event = safe_to_s(binding_info[:capture_event]).capitalize
      source = safe_to_s(binding_info[:source])
      result = ''
      unless exception.to_s == 'NoException'
        origination = "#{capture_event.capitalize}d"
        result += "#{Colors.green(origination)}: #{Colors.blue(source)}"
      end
      method_desc = method_and_args_desc(binding_info[:method_and_args])
      result += method_desc

      variables = binding_info[:variables] || {}

      if variables[:locals] && !variables[:locals].empty?
        result += "\n#{Colors.green('Locals:')}\n#{variable_description(variables[:locals])}"
      end

      instance_vars_to_display = variables[:instances] || {}

      unless instance_vars_to_display.empty?
        result += "\n#{Colors.green('Instances:')}\n#{variable_description(instance_vars_to_display)}"
      end

      if variables[:lets] && !variables[:lets].empty?
        result += "\n#{Colors.green('Let Variables:')}\n#{variable_description(variables[:lets])}"
      end

      if variables[:globals] && !variables[:globals].empty?
        result += "\n#{Colors.green('Globals:')}\n#{variable_description(variables[:globals])}"
      end

      mutex.synchronize do
        max_len = @max_length || DEFAULT_MAX_LENGTH
        if result.length > max_len
          result = result[0...max_len] + "... (truncated)"
        end
      end

      result + "\n"
    rescue => e
      puts "#{e.message}"
      ''
    end

    private


    def handle_tracepoint_event(tp)
      # Check enabled outside the synchronized block for speed, but still safe due to re-check inside.
      return unless mutex.synchronize { @enabled }
      return if Thread.current[:enhanced_errors_processing] || Thread.current[:on_capture] || ignored_exception?(tp.raised_exception)

      Thread.current[:enhanced_errors_processing] = true
      exception = tp.raised_exception

      capture_me = mutex.synchronize do
        !exception.frozen? && (@eligible_for_capture || method(:default_eligible_for_capture)).call(exception)
      end

      unless capture_me
        Thread.current[:enhanced_errors_processing] = false
        return
      end

      binding_context = tp.binding
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

      lets = {}

      globals = {}
      mutex.synchronize do
        if @debug
          globals = (global_variables - @original_global_variables.to_a).map { |var|
            [var, get_global_variable_value(var)]
          }.to_h
        end
      end

      capture_event = safe_to_s(tp.event)
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

      binding_info = default_on_capture(binding_info)
      on_capture_hook_local = mutex.synchronize { @on_capture_hook }

      if on_capture_hook_local
        begin
          Thread.current[:on_capture] = true
          binding_info = on_capture_hook_local.call(binding_info)
        rescue
          binding_info = nil
        ensure
          Thread.current[:on_capture] = false
        end
      end

      if binding_info
        binding_info = validate_binding_format(binding_info)
        if binding_info && exception.binding_infos.length >= MAX_BINDING_INFOS
          exception.binding_infos.delete_at(MAX_BINDING_INFOS / 2.round)
        end
        if binding_info
          exception.binding_infos << binding_info
          mutex.synchronize do
            override_exception_message(exception, exception.binding_infos) if @override_messages
          end
          increment_capture_events_count
        end
      end
    rescue
      # Avoid raising exceptions here
    ensure
      Thread.current[:enhanced_errors_processing] = false
    end

    def ignored_exception?(exception)
      IGNORED_EXCEPTIONS.include?(exception.class.name)
    end

    def test_name
      begin
        defined?(RSpec) ? RSpec&.current_example&.full_description : nil
      rescue
        nil
      end
    end

    def default_capture_events
      mutex.synchronize do
        events = [:raise]
        rescue_available = !!(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0'))
        if capture_rescue && rescue_available
          events << :rescue
        end
        events
      end
    end

    def validate_and_set_capture_events(capture_events)
      mutex.synchronize do
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
          puts "EnhancedErrors: Warning: :rescue capture_event not supported below Ruby 3.3.0, ignoring it."
          capture_events = capture_events - [:rescue]
        end

        if capture_events.empty?
          puts "No valid capture_events provided to EnhancedErrors.enhance_exceptions! Falling back to defaults."
          @capture_events = default_capture_events
          return
        end

        @capture_events = capture_events
      end
    end

    def valid_capture_events?(capture_events)
      capture_events.is_a?(Array) && [:raise, :rescue] && capture_events
    end

    def extract_arguments(tp, method_name)
      return '' unless method_name
      begin
        bind = tp.binding
        unbound_method = tp.defined_class.instance_method(method_name)
        method_obj = unbound_method.bind(tp.self)
        parameters = method_obj.parameters
        locals = bind.local_variables

        parameters.map do |(_, name)|
          value = locals.include?(name) ? safe_local_variable_get(bind, name) : nil
          "#{name}=#{safe_inspect(value)}"
        rescue => e
          "#{name}=[Error getting argument: #{e.message}]"
        end.join(", ")
      rescue => e
        "[Error getting arguments: #{e.message}]"
      end
    end

    def determine_object_name(tp, method_name = '')
      begin
        self_class = Object.instance_method(:class).bind(tp.self).call
        singleton_class = Object.instance_method(:singleton_class).bind(tp.self).call

        if self_class && tp.defined_class == singleton_class
          object_identifier = safe_to_s(tp.self)
          method_suffix = method_name && !method_name.empty? ? ".#{method_name}" : ""
          "#{object_identifier}#{method_suffix}"
        else
          object_class_name = safe_to_s(self_class.name || 'UnknownClass')
          method_suffix = method_name && !method_name.empty? ? "##{method_name}" : ""
          "#{object_class_name}#{method_suffix}"
        end
      rescue
        '[ErrorGettingName]'
      end
    end

    def get_global_variable_value(var)
      var.is_a?(Symbol) ? eval("#{var}") : nil
    rescue => e
      "[Error getting value for #{var}]"
    end

    def method_and_args_desc(method_info)
      object_name = safe_to_s(method_info[:object_name])
      args = safe_to_s(method_info[:args])
      return '' if object_name.empty? && args.empty?
      arg_str = args.empty? ? '' : "(#{args})"
      str = object_name + arg_str
      "\n#{Colors.green('Method: ')}#{Colors.blue(str)}\n"
    rescue
      ''
    end

    def variable_description(vars_hash)
      vars_hash.map do |name, value|
        " #{Colors.purple(name)}: #{format_variable(value)}\n"
      end.join
    rescue
      ''
    end

    def format_variable(variable)
      if awesome_print_available? && Colors.enabled?
        variable.ai
      else
        safe_inspect(variable)
      end
    rescue => e
      var_str = safe_to_s(variable)
      "#{var_str}: [Inspection Error #{e.message}]"
    end

    def awesome_print_available?
      mutex.synchronize do
        return @awesome_print_available unless @awesome_print_available.nil?
        @awesome_print_available = defined?(AwesomePrint)
      end
    end

    def safe_inspect(variable)
      str = variable.inspect
      if str.length > 1200
        str[0...1200] + '...'
      else
        str
      end
    rescue
      safe_to_s(variable)
    end

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

    def safe_local_variable_get(binding_context, var_name)
      binding_context.local_variable_get(var_name)
    rescue
      "[Error accessing local variable #{var_name}]"
    end

    def safe_instance_variable_get(obj, var_name)
      obj.instance_variable_get(var_name)
    rescue
      "[Error accessing instance variable #{var_name}]"
    end

    def default_on_format(string)
      string
    end

    def default_on_capture(binding_info)
      apply_skip_list(binding_info)
    end

    def default_eligible_for_capture(exception)
      ignored = ignored_exception?(exception)
      rspec = exception.class.name.start_with?('RSpec::Matchers')
      !ignored && !rspec
    end
  end
end
