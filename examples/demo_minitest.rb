require 'minitest/autorun'
require 'enhanced_errors'
require 'enhanced/minitest_patch'

# You must install minitest and load it first to run this demo.
# EnhancedErrors does NOT ship with minitest as a dependency.

class MagicBallTest < Minitest::Test
  def setup
    @foo = 'bar'
  end

  def test_boo_capture
    bee = 'fee'
    assert false
  end

  def test_i_raise
    zoo = 'zee'
    raise "Crud"
  end
end
