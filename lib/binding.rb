# binding.rb

module Debugging
  def let_vars_hash
    memoized_values = self.receiver.instance_variable_get(:@__memoized)&.instance_variable_get(:@memoized)
    memoized_values && !memoized_values.empty? ? memoized_values.dup : {}
  end
end

class Binding
  include Debugging
end
