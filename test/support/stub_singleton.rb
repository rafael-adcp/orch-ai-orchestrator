# Minimal singleton-method stub for tests. Minitest 6 dropped Minitest::Mock,
# so we redefine the method on the receiver and restore it in an ensure block.
module StubSingleton
  def stub_singleton(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name) do |*args, **kwargs, &blk|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &blk) : replacement
    end
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end
end

ActiveSupport::TestCase.include(StubSingleton)
ActionDispatch::IntegrationTest.include(StubSingleton)
