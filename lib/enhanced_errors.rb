# enhanced_errors.rb

require 'set'
require 'json'
require 'monitor'

module Enhanced; end

# Exceptions we could handle but overlook for other reasons. These class constants are not always loaded
# and generally are only be available when `required`, so we detect them by strings.
IGNORED_EXCEPTIONS = %w[JSON::ParserError Zlib::Error OpenSSL::SSL::SSLError Psych::BadAlias]
IGNORED_RSPEC_EXCEPTIONS = %w[RSpec::Expectations::ExpectationNotMetError RSpec::Matchers::BuiltIn::RaiseError]

class EnhancedErrors
  extend ::Enhanced

  class << self
    def mutex
      @monitor ||= Monitor.new
    end

    attr_accessor :enabled, :config_block, :on_capture_hook, :eligible_for_capture, :exception_trace, :override_messages

    GEMS_REGEX = %r{[\/\\]gems[\/\\]}
    DEFAULT_MAX_CAPTURE_LENGTH = 2200
    MAX_BINDING_INFOS = 2

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
      :@association_cache,
      :@_routes,
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

    CI_ENV_VARS = {
      'CI' => ENV['CI'],
      'JENKINS' => ENV['JENKINS'],
      'GITHUB_ACTIONS' => ENV['GITHUB_ACTIONS'],
      'CIRCLECI' => ENV['CIRCLECI'],
      'TRAVIS' => ENV['TRAVIS'],
      'APPVEYOR' => ENV['APPVEYOR'],
      'GITLAB_CI' => ENV['GITLAB_CI']
    }

    @enabled = nil
    @max_capture_length = nil
    @capture_rescue = nil
    @skip_list = nil
    @capture_events = nil
    @debug = nil
    @output_format = nil
    @eligible_for_capture = nil
    @original_global_variables = nil
    @exception_trace = nil
    @override_messages = nil

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
      mutex.synchronize { @capture_rescue }
    end

    def max_capture_length
      mutex.synchronize { @max_capture_length || DEFAULT_MAX_CAPTURE_LENGTH }
    end

    def max_capture_length=(value)
      mutex.synchronize { @max_capture_length = value }
    end

    def disable_capturing!
      mutex.synchronize do
        @enabled = false
        @rspec_tracepoint&.disable
        @minitest_trace&.disable
        @exception_trace&.disable
      end
    end

    def reset!
      mutex.synchronize do
        @rspec_tracepoint&.disable
        @minitest_trace&.disable
        @exception_trace&.disable
        @rspec_tracepoint = nil
        @minitest_trace = nil
        @exception_trace = nil
        @enabled = true
      end
    end

    def skip_list
      mutex.synchronize do
        @skip_list ||= DEFAULT_SKIP_LIST.to_set
      end
    end

    def override_rspec_message(example, binding_or_bindings)
      exception_obj = example.exception
      return if exception_obj.nil?

      from_bindings = [binding_or_bindings].flatten.compact
      case exception_obj.class.to_s
      when 'RSpec::Core::MultipleExceptionError'
        exception_obj.all_exceptions.each do |exception|
          override_exception_message(exception, from_bindings + exception.binding_infos)
        end
      when 'RSpec::Expectations::ExpectationNotMetError'
        override_exception_message(exception_obj, binding_or_bindings)
      else
        override_exception_message(exception_obj, from_bindings + exception_obj.binding_infos)
      end
    end

    def override_exception_message(exception, binding_or_bindings)
      variable_str = EnhancedErrors.format(binding_or_bindings)
      message_str = exception.message
      exception.define_singleton_method(:unaltered_message) { message_str }
      exception.define_singleton_method(:message) do
        "#{message_str}#{variable_str}"
      end
    end

    def add_to_skip_list(*vars)
      mutex.synchronize do
        @skip_list.add(*vars)
      end
    end

    def enhance_exceptions!(enabled: true, debug: false, capture_events: nil, override_messages: false, **options, &block)
      mutex.synchronize do
        ensure_extensions_are_required
        @exception_trace&.disable
        @exception_trace = nil

        @output_format = nil
        @eligible_for_capture = nil
        @original_global_variables = nil

        @override_messages = override_messages
        @rspec_failure_message_loaded = true

        @enabled = enabled
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

        events = @capture_events ? @capture_events.to_a : default_capture_events
        @exception_trace = TracePoint.new(*events) do |tp|
          next unless exception_is_handleable?(tp.raised_exception)
          handle_tracepoint_event(tp)
        end

        @exception_trace&.enable if @enabled
      end
    end

    def is_a_minitest?(klass)
      klass.ancestors.include?(Minitest::Test) && klass.name != 'Minitest::Test'
    end

    def start_minitest_binding_capture
      ensure_extensions_are_required
      Enhanced::ExceptionContext.clear_all
      @enabled = true if @enabled.nil?
      return unless @enabled
      mutex.synchronize do
        @minitest_trace = TracePoint.new(:return) do |tp|
          next unless tp.method_id.to_s.start_with?('test_') && is_a_minitest?(tp.defined_class)
          @minitest_test_binding = tp.binding
        end
        @minitest_trace&.enable
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
        (match = klass.to_s.match(/#<Class:(.*?)>/)) ? match[1] : klass.to_s
      else
        klass.to_s
      end
    end

    def is_rspec_example?(tracepoint)
      tracepoint.method_id.nil? && !(tracepoint.path.include?('rspec')) && tracepoint.path.end_with?('_spec.rb')
    end

    def start_rspec_binding_capture
      ensure_extensions_are_required
      Enhanced::ExceptionContext.clear_all
      @enabled = true if @enabled.nil?
      return unless @enabled

      mutex.synchronize do
        @rspec_example_binding = nil
        @capture_next_binding = false
        @rspec_tracepoint&.disable
        @rspec_tracepoint = TracePoint.new(:raise) do |tp|
          case tp.raised_exception.class.name
          when 'RSpec::Expectations::ExpectationNotMetError'
            start_rspec_binding_trap
          else
            handle_tracepoint_event(tp)
          end
        rescue => e
          puts "Error in RSpec binding capture #{e} #{e.backtrace}"
        end
      end
      @rspec_tracepoint&.enable
    end

    # Behavior: Grabs the next rspec spec binding that goes by, and stops the more-expensive b_return trace.
    # This part of RSpec has been stable, since 2015, so although this is kluge-y, it is stable.
    # The optimization does a 2-3x on spec speed vs. opening up the Tracepoint. With it,
    # things are pretty close in speed to plain rspec.
    # Should the behavior change this can be updated by using a trace to print out items
    # and their local variables then, find the exception or call that goes by right
    # before the spec blocks with the variables, and use that to narrow-down the costly part of
    # the probe to just this point in time. The good news is that
    # this part is test-time only, and this optimization and kluge only applies to RSpec.
    def start_rspec_binding_trap
      @rspec_binding_trap = TracePoint.new(:b_return) do |tp|
        # kluge-y hack and will be a pain to maintain
        if tp.callee_id == :handle_matcher
          @capture_next_binding = :next
          next
        end
        next unless @capture_next_binding
        @capture_next_binding = false
        @rspec_example_binding = tp.binding
        @rspec_binding_trap&.disable
        @rspec_binding_trap = nil
      end
      @rspec_binding_trap&.enable
    end

    def stop_rspec_binding_capture
      mutex.synchronize do
        @rspec_tracepoint&.disable
        @rspec_tracepoint = nil
        binding_info = convert_binding_to_binding_info(@rspec_example_binding) if @rspec_example_binding
        @capture_next_binding = false
        @rspec_example_binding = nil
        return binding_info
      end
    end

    def convert_binding_to_binding_info(b, capture_let_variables: true)
      file = b.eval("__FILE__") rescue nil
      line = b.eval("__LINE__") rescue nil
      location = [file, line].compact.join(":")

      locals = b.local_variables.map { |var| [var, safe_local_variable_get(b, var)] }.to_h
      receiver = b.receiver
      return unless safe_to_inspect?(receiver)

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
        capture_event: 'test_context'
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
                           running_in_ci? ? :plaintext : :terminal
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
        @running_in_ci = CI_ENV_VARS.any? { |_, value| value.to_s.downcase == 'true' }
      end
    end

    def apply_skip_list(binding_info)
      binding_info[:variables][:instances]&.reject! { |var, _| skip_list.include?(var) || (var.to_s[0, 2] == '@_' && !@debug) }
      binding_info[:variables][:locals]&.reject! { |var, _| skip_list.include?(var) }
      if @debug
        binding_info[:variables][:globals]&.reject! { |var, _| skip_list.include?(var) }
      end
      binding_info
    end

    def validate_binding_format(binding_info)
      binding_info.keys.include?(:capture_event) && binding_info[:variables].is_a?(Hash)
    end

    # Here, we are detecting BasicObject, which is surprisingly annoying.
    # We also, importantly, need to detect descendants, as they will also present with a
    # lack of :respond_to? and any other useful method for us.
    def safe_to_inspect?(obj)
      begin
        obj.class
      rescue NoMethodError
        return false
      end
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
        max_len = @max_capture_length || DEFAULT_MAX_CAPTURE_LENGTH
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
      return unless enabled
      return if Thread.current[:enhanced_errors_processing] || Thread.current[:on_capture] || ignored_exception?(tp.raised_exception)

      Thread.current[:enhanced_errors_processing] = true
      exception = tp.raised_exception

      return if exception.frozen?

      capture_me = if @eligible_for_capture
                     @eligible_for_capture.call(exception)
                   else
                     default_eligible_for_capture(exception)
                   end

      unless capture_me
        Thread.current[:enhanced_errors_processing] = false
        return
      end

      binding_context = tp.binding
      method_name = tp.method_id
      receiver = binding_context.receiver

      locals = {}

      binding_context.local_variables.each do |var|
        locals[var] = safe_local_variable_get(binding_context, var)
      end

      method_and_args = {
        object_name: determine_object_name(tp, method_name),
        args: extract_arguments(tp, method_name, locals)
      }

      instances = {}

      begin
        if safe_to_inspect?(receiver)
          receiver.instance_variables.each { |var|
            instances[var] = safe_instance_variable_get(receiver, var)
          }
        end
      rescue => e
        puts "#{e.class.name} #{e.backtrace}"
      end

      lets = {}

      globals = {}
      mutex.synchronize do
        if @debug
          globals = (global_variables - @original_global_variables.to_a).each do |var|
            globals[var] = get_global_variable_value(var)
          end
        end
      end

      capture_event = tp.event.to_s
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
        exception: exception.class.name,
        capture_event: capture_event
      }

      binding_info = default_on_capture(binding_info)

      if on_capture_hook
        begin
          Thread.current[:on_capture] = true
          binding_info = on_capture_hook.call(binding_info)
        rescue
          binding_info = nil
        ensure
          Thread.current[:on_capture] = false
        end
      end

      return unless binding_info && validate_binding_format(binding_info)
      if exception.binding_infos.length >= MAX_BINDING_INFOS
        exception.binding_infos.delete_at(MAX_BINDING_INFOS / 2.round)
      end
      exception.binding_infos << binding_info
      mutex.synchronize do
        override_exception_message(exception, exception.binding_infos) if @override_messages
      end
    rescue => e
      puts "Error: #{e&.class&.name} #{e&.backtrace}"
    ensure
      Thread.current[:enhanced_errors_processing] = false
    end

    # Specifically avoid psych, and system level libraries, or libraries where variable context isn't
    # likely to be particularly helpful or relevant.
    def ignored_exception?(exception)
      name = exception.class.name
      IGNORED_EXCEPTIONS.include?(name) || name =~ /^(Gem|Psych|Zlib|OpenSSL|DRb|Prism|Reline|Fiddle)::/
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
      capture_events.is_a?(Array) && capture_events.all? { |ev| [:raise, :rescue].include?(ev) }
    end

    def extract_arguments(tp, method_name, local_vars_hash)
      return '' unless method_name
      begin
        unbound_method = tp.defined_class.instance_method(method_name)
        method_obj = unbound_method.bind(tp.self)
        parameters = method_obj.parameters

        parameters.map do |(_, name)|
          value = local_vars_hash[name]
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
        # Check if we're dealing with a singleton method
        if (
          class << tp.self
            self;
          end) == tp.defined_class
          # Singleton method call
          object_str = safe_to_s(tp.self)
          method_suffix = method_name.to_s.empty? ? '' : ".#{method_name}"
          "#{object_str}#{method_suffix}"
        else
          # Instance method call
          klass_name = safe_to_s(tp.self.class.name || 'UnknownClass')
          method_suffix = method_name.to_s.empty? ? '' : "##{method_name}"
          "#{klass_name}#{method_suffix}"
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

    # By default, we have filtering for safety, but past that, we capture everything by default
    # at the moment.
    def default_eligible_for_capture(exception)
      ignored = ignored_exception?(exception) || IGNORED_RSPEC_EXCEPTIONS.include?(exception.class.name)
      rspec = exception.class.name.start_with?('RSpec::Matchers')
      !(ignored || rspec)
    end

    # overall--do we process this, including whether we ignore it or not for more general reasons
    def exception_is_handleable?(exception)
      exception && processable_exception?(exception) && !ignored_exception?(exception)
    end

    # some exceptions, we just don't want to touch
    def processable_exception?(exception)
      case exception
      when SystemExit, SignalException, SystemStackError, NoMemoryError
        # Non-actionable: Ignore these exceptions
        false
      when SyntaxError, LoadError, ScriptError
        # Non-actionable: Structural issues so there's no useful runtime context
        false
      else
        # Ignore internal fatal errors
        exception.class.to_s != 'fatal'
      end
    end

    # This prevents loading it for say, production, if you don't want to,
    # and keeps things cleaner. It allows a path to put this behind a feature-flag
    # or env variable, and dynamically enable some capture instrumentation only
    # when a Heisenbug is being hunted.
    def ensure_extensions_are_required
      mutex.synchronize do
        return if @loaded_required_extensions
        require_relative 'enhanced/colors'
        require_relative 'enhanced/exception'
        @loaded_required_extensions = true
      end
    end

  end
end
