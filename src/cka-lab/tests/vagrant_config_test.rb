require "minitest/autorun"
require "open3"

class ConfigProbe
  attr_reader :calls

  def initialize
    @calls = []
  end

  def vm
    self
  end

  def trigger
    self
  end

  def method_missing(name, *arguments, **options, &block)
    child = ConfigProbe.new
    @calls << { name: name, arguments: arguments, options: options, child: child }
    block.call(child) if block && name != :ruby
    child
  end

  def respond_to_missing?(_name, _include_private = false)
    true
  end
end

module Vagrant
  class << self
    attr_accessor :config

    def configure(_version)
      self.config = ConfigProbe.new
      yield config
    end
  end

  module Util
    module Platform
      class << self
        attr_accessor :windows

        def windows?
          windows
        end
      end
    end
  end
end

class VagrantConfigTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def load_config(windows:)
    previous_provider = ENV.delete("VAGRANT_DEFAULT_PROVIDER")
    previous_verbose = $VERBOSE
    $VERBOSE = nil
    Vagrant::Util::Platform.windows = windows
    load File.join(ROOT, "Vagrantfile")
    yield Vagrant.config
  ensure
    ENV["VAGRANT_DEFAULT_PROVIDER"] = previous_provider
    $VERBOSE = previous_verbose
  end

  def nodes(config)
    config.calls.select { |call| call[:name] == :define }
  end

  def test_linux_networks_and_provisioners
    load_config(windows: false) do |config|
      assert_equal "libvirt", ENV["VAGRANT_DEFAULT_PROVIDER"]
      refute config.calls.any? { |call| call[:name] == :before }
      assert_equal 3, nodes(config).length
      nodes(config).each_with_index do |node, index|
        calls = node[:child].calls
        network = calls.find { |call| call[:name] == :network }
        assert_equal ["private_network"], network[:arguments]
        assert_equal "192.168.50.#{10 + index}", network[:options][:ip]
        assert_equal "cka-lab", network[:options][:libvirt__network_name]
        assert_equal false, network[:options][:libvirt__dhcp_enabled]
        assert_equal false, network[:options][:auto_config]
        refute calls.any? { |call| call[:options][:name] == "static-ip" }
        lab_network = calls.find { |call| call[:options][:name] == "libvirt-network" }
        assert_equal node[:arguments].first, lab_network[:options][:env]["NODE_NAME"]
        assert_equal network[:options][:ip], lab_network[:options][:env]["NODE_IP"]
        assert_includes lab_network[:options][:inline], 'hostnamectl set-hostname "$NODE_NAME"'
        assert_includes lab_network[:options][:inline], "    eth1:"
        refute_includes lab_network[:options][:inline], "    eth0:"
        provider = calls.find { |call| call[:arguments] == ["libvirt"] }
        address = provider[:child].calls.find { |call| call[:name] == :management_network_address= }
        assert_equal ["172.28.50.0/24"], address[:arguments]
        prereqs = calls.find { |call| call[:options][:name] == "cka-prereqs" }
        assert_equal network[:options][:ip], prereqs[:options][:env]["NODE_IP"]
      end
    end
  end

  def test_windows_retains_hyperv_networking
    load_config(windows: true) do |config|
      assert_equal "hyperv", ENV["VAGRANT_DEFAULT_PROVIDER"]
      assert config.calls.any? { |call| call[:name] == :before }
      nodes(config).each do |node|
        calls = node[:child].calls
        network = calls.find { |call| call[:name] == :network }
        assert_equal ["public_network"], network[:arguments]
        assert_equal "CKA-NAT", network[:options][:bridge]
        assert_equal false, network[:options][:auto_config]
        assert calls.any? { |call| call[:options][:name] == "static-ip" }
        refute calls.any? { |call| call[:options][:name] == "libvirt-network" }
      end
    end
  end

  def test_embedded_shell_syntax_on_both_platforms
    [false, true].each do |windows|
      load_config(windows: windows) do |config|
        nodes(config).each do |node|
          node[:child].calls.select { |call| call[:name] == :provision }.each do |provisioner|
            output, status = Open3.capture2e("bash", "-n", stdin_data: provisioner[:options][:inline])
            assert status.success?, "#{provisioner[:options][:name]}: #{output}"
          end
        end
      end
    end
  end

  def test_bootstrap_prefers_lab_ip_and_allows_fallback_or_override
    prefix = File.read(File.join(ROOT, "bootstrap_cp.sh")).split('echo "Initializing control plane..."').first
    [["192.168.50.10", nil, "192.168.50.10"],
     [nil, nil, "172.28.50.10"],
     ["192.168.50.10", "10.0.0.10", "10.0.0.10"]].each do |lab, override, expected|
      records = "2: eth0 inet 172.28.50.10/24 scope global eth0\n"
      records += "3: eth1 inet #{lab}/24 scope global eth1\n" if lab
      mocks = "ip() { printf %b #{records.dump}; }; hostname() { echo 172.28.50.10; };\n"
      output, status = Open3.capture2e({ "CP_IP" => override }, "bash", stdin_data: mocks + prefix)
      assert status.success?, output
      assert_includes output, "Control plane IP detected: #{expected}"
    end
  end
end