require 'logger'

module ExampleGroupMethods
  def uses_logger
    let(:logger) { instance_double(Logger, 'mock') }

    before(:each) do
      allow(logger).to receive(:debug)
      allow(logger).to receive(:info)
    end
  end
end
