require 'securerandom'
require 'fileutils'
require 'tmpdir'
require 'etc'

%w(
  helpers/base helpers/options helpers/copies lxc
  storage/overlay_directory storage/overlay_mount
  storage/virtual_device
).each do |path|
  require "elecksee/#{path}"
end

class Lxc

  class Ephemeral

    include Helpers
    include Helpers::Options
    include Helpers::Copies

    option :original, '-o', :string, :required => true, :desc => 'Original container name'
    option :ipaddress, '-I', :string, :desc => 'Custom IP address'
    option :gateway, '-G', :string, :desc => 'Custom gateway'
    option :netmask, '-N', :string, :default => '255.255.255.0', :desc => 'Custom netmask'
    option :device, '-D', :integer, :desc => 'Create VBD for overlay of size {SIZE}M'
    option :directory, '-z', :boolean, :desc => 'Use host based directory for overlay'
    option :union, '-U', :string, :desc => 'Overlay FS to use (overlayfs or aufs)'
    option :daemon, '-d', :boolean, :desc => 'Run as a daemon'
    option :bind, '-b', :string, :desc => 'Bind provided directory (non-ephemeral)'
    option :user, '-u', :string, :desc => 'Deprecated: Provided for compatibility'
    option :ssh_key, '-S', :string, :default => '/opt/hw-lxc-config/id_rsa', :aliases => 'ssh-key', :desc => 'Deprecated: Provided for compatibility'
    option :lxc_dir, '-L', :string, :default => '/var/lib/lxc', :aliases => 'lxc-dir', :desc => 'Directory of LXC store'
    option :tmp_dir, '-T', :string, :default => '/tmp/lxc/ephemerals', :aliases => 'tmp-dir', :desc => 'Directory of ephemeral temp files'
    option :ephemeral_command, '-C', :string, :aliases => 'command'

    attr_reader :name
    attr_reader :cli
    attr_reader :hostname
    attr_reader :path
    attr_reader :lxc
    attr_reader :ephemeral_device
    attr_reader :ephemeral_overlay
    attr_reader :ephemeral_binds

    def initialize(args={})
      configure!(args)
      @cli = args[:cli]
      @path = command("mktemp -d -p #{lxc_dir} #{original}-XXXXXXXXXXXX", :sudo => true).stdout.strip
      command("chmod 0755 #{@path}", :sudo => true)
      @name = File.basename(@path)
      @hostname = @name.gsub(%r{[^A-Za-z0-9\-]}, '')
      @ephemeral_binds = []
      @lxc = nil
    end

    def register_traps
      %w(TERM INT QUIT).each do |sig|
        Signal.trap(sig){ cleanup && raise }
      end
    end

    def cli_output
      if(cli)
        puts "New ephemeral container started. (#{name})"
        puts "    - Connect using: sudo ssh -i #{ssh_key} root@#{lxc.container_ip(10)}"
      end
    end

    def start_action
      begin
        lxc.start
        if(ephemeral_command)
          lxc.wait_for_state(:running)
          lxc.container_command(ephemeral_command)
        else
          cli_output
          lxc.wait_for_state(:stopped)
        end
      ensure
        cleanup
      end
      true
    end

    def create!
      setup
    end

    def start!(*args)
      register_traps
      setup
      if(daemon)
        if(args.include?(:fork))
          fork do
            start_action
          end
        else
          Process.daemon
          start_action
        end
      else
        start_action
      end
    end

    def cleanup
      lxc.stop
      @ephemeral_overlay.unmount
      @ephemeral_binds.map(&:destroy)
      @ephemeral_device.destroy
      if(lxc.path.to_path.split('/').size > 1)
        command("rm -rf #{lxc.path.to_path}", :sudo => true)
        true
      else
        $stderr.puts "This path seems bad and I won't remove it: #{lxc.path.to_path}"
        false
      end
    end

    private

    def setup
      create
      build_overlay
      update_naming
      discover_binds
      apply_custom_networking if ipaddress
    end

    def build_overlay
      if(directory)
        @ephemeral_device = OverlayDirectory.new(name, :tmp_dir => directory.is_a?(String) ? directory : tmp_dir)
      else
        @ephemeral_device = VirtualDevice.new(name, :size => device, :tmp_fs => !device, :tmp_dir => tmp_dir)
        @ephemeral_device.mount
      end
      @ephemeral_overlay = OverlayMount.new(
        :base => Lxc.new(original).rootfs.to_path,
        :overlay => ephemeral_device.target_path,
        :target => lxc.path.join('rootfs').to_path,
        :overlay_type => union
      )
      @ephemeral_overlay.mount
    end

    def create
      Dir.glob(File.join(lxc_dir, original, '*')).each do |o_path|
        next unless File.file?(o_path)
        command("cp #{o_path} #{File.join(path, File.basename(o_path))}", :sudo => true)
      end
      @lxc = Lxc.new(name)
      command("mkdir -p #{lxc.path.join('rootfs')}", :sudo => true)
      update_net_hwaddr
    end

    # TODO: Discovered binds for ephemeral are all tmpfs for now.
    # TODO: We should default to overlay mount, make virt dev optional
    def discover_binds
      contents = File.readlines(lxc.path.join('fstab')).each do |line|
        parts = line.split(' ')
        if(parts[3] == 'bind')
          source = parts.first
          target = parts[1].sub(%r{^.+rootfs/}, '')
          container_target = lxc.rootfs.join(target).to_path
          device = VirtualDevice.new(target.gsub('/', '_'), :tmp_fs => true)
          device.mount
          FileUtils.mkdir_p(container_target)
          ephemeral_binds << device
          if(union == 'overlayfs')
            "none #{container_target} overlayfs upperdir=#{device.mount_path},lowerdir=#{source} 0 0"
          else
            "none #{container_target} aufs br=#{device.mount_path}=rw:#{source}=ro,noplink 0 0"
          end
        else
          line
        end
      end
      # If bind option used, bind in for rw
      if(bind)
        command("mkdir -p #{lxc.rootfs.join(bind).to_path}", :sudo => true)
        contents << "#{bind} #{lxc.rootfs.join(bind)} none bind 0 0\n"
      end
      write_file(lxc.path.join('fstab'), contents.join)
    end
  end
end
