require 'spec_helper'
require_relative '../lib/enhanced_errors'

RSpec.describe EnhancedErrors do
  before(:each) do
    EnhancedErrors.enhance!
  end

  describe 'Exception enhancement' do
    let(:let_variable) { 'let_value' }

    before(:each) do
      @instance_variable = 'instance_value'
    end

    it 'captures RSpec let variables when an exception is raised' do
      lv = let_variable  # Ensure let_variable is evaluated
      begin
        raise 'Test exception'
      rescue => e
        expect(e.message).to include('let_value')
      end
    end

    it 'captures instance variables when an exception is raised' do
      begin
        raise 'Test exception'
      rescue => e
        binding_infos = e.instance_variable_get(:@binding_infos)
        last_binding_info = binding_infos.last
        instances = last_binding_info[:variables][:instances]
        expect(instances).to include(:@instance_variable)
        expect(instances[:@instance_variable]).to eq('instance_value')
      end
    end

    it 'applies correct defaults based on environment' do
      # Simulate 'development' environment
      ENV['RAILS_ENV'] = 'development'
      EnhancedErrors.enhance!
      expect(EnhancedErrors.get_default_format_for_environment).to eq(:terminal)

      # Simulate 'production' environment
      ENV['RAILS_ENV'] = 'production'
      EnhancedErrors.enhance!
      expect(EnhancedErrors.get_default_format_for_environment).to eq(:json)

      # Clean up environment variable
      ENV.delete('RAILS_ENV')
    end

    it 'excludes variables in the skip list from binding information' do
      @variable_to_skip = 'should be skipped'
      @variable_to_include = 'should be included'

      EnhancedErrors.enhance! do
        add_to_skip_list :@variable_to_skip
      end

      begin
        raise 'Test exception'
      rescue => e
        binding_infos = e.instance_variable_get(:@binding_infos)
        last_binding_info = binding_infos.last
        instances = last_binding_info[:variables][:instances]

        expect(instances).to include(:@variable_to_include)
        expect(instances).not_to include(:@variable_to_skip)
      end
    end

    it 'truncates output according to max_length' do
      large_string = 'a' * 5000  # 5000 characters
      @large_variable = large_string

      EnhancedErrors.enhance! do
        max_length 1000
      end

      begin
        raise 'Test exception'
      rescue => e
        expect(e.message.length).to be <= 1500  # Allowing extra for exception message and formatting
      end
    end

    context 'hooks' do
      before do
        # Reset EnhancedErrors configuration before each test
        EnhancedErrors.enhance!
        EnhancedErrors.on_capture = nil
      end

      describe 'on_capture hook' do
        it 'allows modification of the binding info structures' do
          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            binding_info[:variables][:locals].each do |key, value|
              if key == :password
                binding_info[:variables][:locals][key] = '[REDACTED]'
              end
            end
            captured_binding_infos << binding_info
            binding_info  # Return the modified binding_info
          end

          begin
            username = 'test_user'
            password = 'super_secret'
            raise 'Authentication failed'
          rescue => e
            @exception = e
          end

          expect(captured_binding_infos).not_to be_empty
          locals = captured_binding_infos.first[:variables][:locals]
          expect(locals[:username]).to eq('test_user')
          expect(locals[:password]).to eq('[REDACTED]')
        end
      end

      describe 'variables_message method' do
        it 'captures binding information' do
          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            captured_binding_infos << binding_info
            binding_info  # Return the binding_info
          end

          begin
            raise 'Test exception'
          rescue => e
            @exception = e
          end
          expect(captured_binding_infos).not_to be_empty
        end

        it 'returns the variable message separately' do
          begin
            local_var = 'test_value'
            raise 'An error occurred'
          rescue => e
            @exception = e
          end

          expect(@exception).to respond_to(:variables_message)
          expect(@exception.variables_message).to include('Locals:')
          expect(@exception.variables_message).to include('local_var')
          expect(@exception.variables_message).to include('test_value')
        end
      end

      describe 'capture_type field in binding info' do
        it 'has capture_type set to "raise" when an exception is raised' do
          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            captured_binding_infos << binding_info
            binding_info  # Return the binding_info
          end

          begin
            raise 'Test exception'
          rescue => e
            @exception = e
          end

          expect(captured_binding_infos.first[:capture_type]).to eq('raise')
        end

        it 'has capture_type set to "rescue" when an exception is rescued' do
          # Skip this test if Ruby version < 3.3.0
          if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.3.0')
            skip 'Ruby version does not support :rescue event in TracePoint'
          end

          # Arrange
          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            captured_binding_infos << binding_info
            binding_info  # Return the binding_info
          end

          begin
            raise 'Test exception'
          rescue => e
            # Exception is rescued here
          end

          rescue_info = captured_binding_infos.find { |info| info[:capture_type] == 'rescue' }
          expect(rescue_info).not_to be_nil
          expect(rescue_info[:capture_type]).to eq('rescue')
        end
      end
    end

    it 'captures method and arguments in different contexts' do
      class TestClass
        def self.class_method(arg1)
          raise 'Exception in class method'
        end

        def instance_method(arg1, arg2)
          raise 'Exception in instance method'
        end
      end

      # Class method
      begin
        TestClass.class_method('value1')
      rescue => e_class
        binding_infos = e_class.instance_variable_get(:@binding_infos)
        last_binding_info = binding_infos.last
        method_and_args = last_binding_info[:method_and_args]

        expect(method_and_args[:object_name]).to eq('TestClass.class_method')
        expect(method_and_args[:args]).to include("arg1=\"value1\"")
      end

      # Instance method
      begin
        obj = TestClass.new
        obj.instance_method('value1', 'value2')
      rescue => e_instance
        binding_infos = e_instance.instance_variable_get(:@binding_infos)
        last_binding_info = binding_infos.last
        method_and_args = last_binding_info[:method_and_args]

        expect(method_and_args[:object_name]).to eq('TestClass#instance_method')
        expect(method_and_args[:args]).to include("arg1=\"value1\"", "arg2=\"value2\"")
      end
    end

    it 'captures binding information when exceptions are rescued and re-raised' do
      def method_with_rescue
        begin
          raise 'Initial exception'
        rescue
          # Do some processing
          raise # Re-raise the exception
        end
      end

      begin
        method_with_rescue
      rescue => e
        binding_infos = e.instance_variable_get(:@binding_infos)
        expect(binding_infos.size).to be >= 2

        first_binding_info = binding_infos.first
        last_binding_info = binding_infos.last

        expect(first_binding_info[:method_and_args][:object_name]).to include('method_with_rescue')
        expect(last_binding_info[:method_and_args][:object_name]).to include('method_with_rescue')
      end
    end

    it 'manages TracePoint correctly when start_tracing is called multiple times' do
      EnhancedErrors.enhance!
      first_trace = EnhancedErrors.trace

      EnhancedErrors.enhance!
      second_trace = EnhancedErrors.trace

      expect(first_trace).to eq(second_trace)
      expect(EnhancedErrors.trace.enabled?).to be true

      EnhancedErrors.enhance!(enabled: false)
      expect(EnhancedErrors.trace.enabled?).to be false
    end

    it 'remains disabled after being disabled until explicitly re-enabled' do
      EnhancedErrors.enhance!(enabled: false)
      expect(EnhancedErrors.enabled).to be false

      # Simulate exception
      begin
        raise 'Test exception while disabled'
      rescue => e
        expect(e.instance_variable_get(:@binding_infos)).to be_nil
      end

      # Enhancements should remain disabled
      expect(EnhancedErrors.enabled).to be false

      # Explicitly re-enable enhancements
      EnhancedErrors.enhance!(enabled: true)
      expect(EnhancedErrors.enabled).to be true
    end

    it 'enables and disables colorization in Colors based on format' do
      # Simulate 'development' environment
      ENV['RAILS_ENV'] = 'development'
      EnhancedErrors.enhance!
      expect(EnhancedErrors.get_default_format_for_environment).to eq(:terminal)

      begin
        raise 'Test exception with color'
      rescue => e
        e.message # Trigger variables_message
        expect(Colors.enabled?).to be true
        expect(e.message).to include("\e[") # Check for color codes
      end

      # Simulate 'production' environment
      ENV['RAILS_ENV'] = 'production'
      EnhancedErrors.enhance!
      expect(EnhancedErrors.get_default_format_for_environment).to eq(:json)

      begin
        raise 'Test exception without color'
      rescue => e
        e.message # Trigger variables_message
        expect(Colors.enabled?).to be false
        expect(e.message).not_to include("\e[")
      end

      # Clean up environment variable
      ENV.delete('RAILS_ENV')
    end

    it 'enables and disables tracing and checks exception enhancement' do
      EnhancedErrors.enhance!(enabled: false)
      expect(EnhancedErrors.enabled).to be false

      begin
        raise 'Test exception without tracing'
      rescue => e
        binding_infos = e.instance_variable_get(:@binding_infos)
        expect(binding_infos).to be_nil
      end

      EnhancedErrors.enhance!(enabled: true)
      expect(EnhancedErrors.enabled).to be true

      begin
        raise 'Test exception with tracing'
      rescue => e
        binding_infos = e.instance_variable_get(:@binding_infos)
        expect(binding_infos).not_to be_nil
      end
    end

    context 'eligible_for_capture' do
      before do
        # Reset EnhancedErrors configuration before each test
        EnhancedErrors.enhance!
        EnhancedErrors.on_capture = nil
      end

      after do
        EnhancedErrors.on_capture = nil
      end

      it 'ignores exceptions that are not eligible for capture' do
        EnhancedErrors.enhance! do
          eligible_for_capture do |exception|
            false
          end
        end

        begin
          raise 'Test exception'
        rescue => e
          expect(e.instance_variable_get(:@binding_infos)).to be_nil
        end
      end

      it 'ignores exceptions that are not eligible for capture' do
        EnhancedErrors.enhance! do
          eligible_for_capture do |exception|
            true
          end
        end

        begin
          raise 'Test exception'
        rescue => e
          expect(e.instance_variable_get(:@binding_infos)).to_not be_nil
        end
      end


    end

    context 'global variables' do

        before(:each) do
          EnhancedErrors.enhance!(debug: false)
        end

        describe 'Global Variable Capture with Shared Skip List' do

          it 'captures new global variables when in debug mode, ignoring the skip list' do
            $variable_to_skip = 'should not be captured in debug mode as was present before enhance! call'
            EnhancedErrors.enhance!(debug: true)
            $variable_to_include = 'should be included as happened after'

            begin
              raise 'Test exception with global variables in debug mode'
            rescue => e
              expect(e.message).to_not include('$variable_to_skip')
              expect(e.message).to include('$variable_to_include')
            ensure
              $variable_to_skip = nil
              $variable_to_include = nil
            end
          end
        end

      end

  end
end
