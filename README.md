# EnhancedErrors

## Overview

**EnhancedErrors** is a pure Ruby gem that enhances exception messages by capturing and appending variables and their values from the scope where the error was raised.

**EnhancedErrors** leverages Ruby's built-in [TracePoint](https://ruby-doc.org/core-3.1.0/TracePoint.html) feature to provide detailed context for exceptions, making debugging easier without significant performance overhead.

## Features

- **Pure Ruby**: No external dependencies or C extensions.
- **Standalone**: Does not rely on any external libraries.
- **Lightweight**: Minimal performance impact, as tracing is only active during exception raising.
- **Customizable Output**: Supports multiple output formats (`:json`, `:plaintext`, `:terminal`).
- **Flexible Hooks**: Allows redacting or modifying captured data via the `on_capture` hook.
- **Environment-Based Defaults**: For Rails apps, automatically adjusts settings based on the environment (`development`, `test`, `production`, `ci`).
- **Pre-Populated Skip List**: Comes with predefined skip lists to exclude irrelevant variables from being captured.
- **Redaction Support**: Enables removal of Personally Identifiable Information (PII), healthcare data, and other sensitive information.
- **Capture Levels**: Supports `info` and `debug` levels, where `debug` level ignores the skip lists for more comprehensive data capture.
- **Capture Types**: Captures the first `raise` and the last `rescue` by default.
- **Global Variable Capture**: Although global variable capture was previously supported, it is no longer functional. This is acknowledged in the documentation.



## Installation

Add this line to your application's `Gemfile`:

```ruby
gem 'enhanced_errors'
```

And then execute:

```shell
$ bundle install
```

Or install it yourself with:

```shell
$ gem install enhanced_errors
```

## Usage

### Basic Setup

To enable EnhancedErrors, call the `enhance!` method:

```ruby
EnhancedErrors.enhance!
```

This activates the TracePoint to start capturing exceptions and their surrounding context.

### Configuration Options

You can pass configuration options to `enhance!`:

```ruby
EnhancedErrors.enhance!(enabled: true, max_length: 2000) do
  # Additional configuration here
end
```

- `enabled`: Enables or disables the enhancement (default: `true`).
- `max_length`: Sets the maximum length of the enhanced message (default: `2500`).

### Environment-Based Defaults

EnhancedErrors adjusts its default settings based on the environment:

- **Development/Test**:
    - Default Output format: `:terminal`
    - Terminal Color output: Enabled
- **Production**:
    - Output format: `:json`
    - Terminal Color output: Disabled
- **CI Environment**:
    - Output format: `:plaintext`
    - Color output: Disabled

The environment is determined by `ENV['RAILS_ENV']`, `ENV['RACK_ENV']`, or detected CI environment variables like:
- `CI=true`

### Output Formats

You can customize the output format:

- **`:json`**: Outputs the captured data in JSON format.
- **`:plaintext`**: Outputs plain text without color codes.
- **`:terminal`**: Outputs text with terminal color codes.

Example:

```ruby
EnhancedErrors.format(captured_bindings, :json)
```

### Customizing Data Capture

#### Using `on_capture`

The `on_capture` hook allows you to modify or redact data as it's captured:

```ruby
EnhancedErrors.on_capture do |binding_info|
  # Redact sensitive data
  if binding_info[:variables][:locals][:password]
    binding_info[:variables][:locals][:password] = '[REDACTED]'
  end
  binding_info  # Return the modified binding_info
end
```

**Redaction Explanation**: Redacting is essential to remove Personally Identifiable Information (PII), healthcare data, or other sensitive information from exception messages. This ensures that sensitive data is not exposed in logs or error reports, maintaining compliance with data protection regulations.

#### Applying a Skip List

EnhancedErrors comes with predefined skip lists to exclude sensitive or irrelevant variables. You can add additional variables to the skip list as needed:

```ruby
EnhancedErrors.add_to_skip_list :@sensitive_variable, :$global_secret
```

The skip list is pre-populated with common variables to exclude and can be extended based on your application's requirements. In `debug` mode, additional variables are included as per the skip list configurations.

### Capture Levels

EnhancedErrors supports different capture levels to control the verbosity of the captured data:

- **Info Level**: Respects the skip list, excluding predefined sensitive or irrelevant variables.
- **Debug Level**: Ignores the skip lists, capturing all variables including those typically excluded.

**Default Behavior**: By default, `info` level is used, which excludes variables in the skip list to protect sensitive information. In `debug` mode, the skip lists are ignored to provide more comprehensive data, which is useful during development but should be used cautiously to avoid exposing sensitive data.

### Capture Types

EnhancedErrors differentiates between two types of capture events:

- **`raise`**: Captures the context when an exception is initially raised.
- **`rescue`**: Captures the context when an exception is rescued.

**Default Behavior**: By default, EnhancedErrors returns the first `raise` and the last `rescue` event for each exception. This provides a clear picture of where and how the exception was handled.

### Custom Formatting

You can define a custom format for the captured data:

```ruby
def custom_format(captured_bindings)
  captured_bindings.map do |binding_info|
    # Encrypt the variables for security
    binding_info[:variables] = encrypt_variables(binding_info[:variables])
    binding_info.to_s
  end.join("\n")
end

EnhancedErrors.format(captured_bindings, :custom_format)
```

### Example: Redacting Sensitive Information

```ruby
EnhancedErrors.on_capture do |binding_info|
  sensitive_keys = [:password, :ssn, :health_info]
  sensitive_keys.each do |key|
    if binding_info[:variables][:locals][key]
      binding_info[:variables][:locals][key] = '[REDACTED]'
    end
  end
  binding_info
end
```

### Example: Encrypting Data in Custom Format

```ruby
require 'openssl'

def encrypt_variables(variables)
  cipher = OpenSSL::Cipher.new('AES-128-CBC').encrypt
  cipher.key = 'a secret key'
  variables.each do |type, vars|
    vars.each do |key, value|
      encrypted = cipher.update(value.to_s) + cipher.final
      vars[key] = encrypted.unpack1('H*')  # Convert to hex string
    end
  end
  variables
end

def encrypted_format(captured_bindings)
  captured_bindings.map do |binding_info|
    binding_info[:variables] = encrypt_variables(binding_info[:variables])
    binding_info.to_s
  end.join("\n")
end

EnhancedErrors.on_capture do |binding_info|
  binding_info
end

# Set the custom format
def custom_format_method(captured_bindings)
  encrypted_format(captured_bindings)
end

# Use the custom format
EnhancedErrors.format(captured_bindings, :custom_format)
```

## How It Works

EnhancedErrors uses Ruby's `TracePoint` to listen for `:raise` and `:rescue` events. When an exception is raised or rescued, it captures:

- **Local Variables**: Variables local to the scope where the exception occurred.
- **Instance Variables**: Instance variables of the object.
- **Method and Arguments**: The method name and its arguments.
- **Let Variables**: RSpec let variables, if applicable. Only memoized (evaluated) let variables are captured.
- **Global Variables**: Global variables, in debug mode.

The captured data includes a `capture_type` field indicating whether the data was captured during a `raise` or `rescue` event. By default, EnhancedErrors returns the first `raise` and the last `rescue` event for each exception, providing a clear trace of the exception lifecycle.

The captured data is then appended to the exception's message, providing rich context for debugging.

## Performance Considerations

- **Minimal Overhead**: Since TracePoint is only activated during exception raising and rescuing, the performance impact is negligible during normal operation.
- **Production Safe**: The gem is designed to be safe for production use, giving you valuable insights without compromising performance.

## Security Considerations

- **Redacting Sensitive Data**: Use the `on_capture` hook to redact or remove Personally Identifiable Information (PII), healthcare data, or other sensitive information before it gets appended to exception messages. This is crucial for maintaining compliance with data protection regulations and ensuring that sensitive information is not exposed in logs or error reports.

## Contributing

Bug reports and pull requests are welcome on GitHub at [https://github.com/your_username/enhanced_errors](https://github.com/your_username/enhanced_errors).

## License

The gem is available as open-source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

