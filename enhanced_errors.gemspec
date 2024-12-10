Gem::Specification.new do |spec|
  spec.name = "enhanced_errors"
  spec.version = "2.0.3"
  spec.authors = ["Eric Beland"]

  spec.summary = "Automatically enhance your errors with messages containing variable values from the moment they were raised."
  spec.description = "EnhancedErrors will automatically enhance your errors with messages containing variable values from the moment they were raised, using no extra dependencies, and only Ruby's built-in TracePoint. "
  spec.homepage = "https://github.com/ericbeland/enhanced_errors"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ericbeland/enhanced_errors"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .circleci appveyor Gemfile])
    end
  end
  spec.require_paths = ["lib"]

  spec.add_development_dependency "awesome_print", "~> 1.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency 'yard', '~> 0.9'
end
