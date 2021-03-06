require 'log4r'

require 'vagrant/util/file_mode'
require 'vagrant/util/platform'
require 'vagrant/util/safe_exec'

module Vagrant
  # Manages SSH connection information as well as allows opening an
  # SSH connection.
  class SSH
    include Util::SafeExec

    def initialize(vm)
      @vm     = vm
      @logger = Log4r::Logger.new("vagrant::ssh")
    end

    # Returns a hash of information necessary for accessing this
    # virtual machine via SSH.
    #
    # @return [Hash]
    def info
      results = {
        :host          => @vm.config.ssh.host,
        :port          => @vm.config.ssh.port || @vm.driver.ssh_port(@vm.config.ssh.guest_port),
        :username      => @vm.config.ssh.username,
        :forward_agent => @vm.config.ssh.forward_agent,
        :forward_x11   => @vm.config.ssh.forward_x11
      }

      # This can happen if no port is set and for some reason Vagrant
      # can't detect an SSH port.
      raise Errors::SSHPortNotDetected if !results[:port]

      # Determine the private key path, which is either set by the
      # configuration or uses just the built-in insecure key.
      pk_path = @vm.config.ssh.private_key_path || @vm.env.default_private_key_path
      results[:private_key_path] = File.expand_path(pk_path, @vm.env.root_path)

      # We need to check and fix the private key permissions
      # to make sure that SSH gets a key with 0600 perms.
      check_key_permissions(results[:private_key_path])

      # Return the results
      return results
    end

    # Connects to the environment's virtual machine, replacing the ruby
    # process with an SSH process.
    #
    # @param [Hash] opts Options hash
    # @options opts [Boolean] :plain_mode If True, doesn't authenticate with
    #   the machine, only connects, allowing the user to connect.
    def exec(opts={})
      # Get the SSH information and cache it here
      ssh_info = info

      if Util::Platform.windows?
        raise Errors::SSHUnavailableWindows, :key_path => ssh_info[:private_key_path],
                                             :ssh_port => ssh_info[:port]
      end

      raise Errors::SSHUnavailable if !Kernel.system("which ssh > /dev/null 2>&1")

      # If plain mode is enabled then we don't do any authentication (we don't
      # set a user or an identity file)
      plain_mode = opts[:plain_mode]

      options = {}
      options[:host] = ssh_info[:host]
      options[:port] = ssh_info[:port]
      options[:username] = ssh_info[:username]
      options[:private_key_path] = ssh_info[:private_key_path]

      # Command line options
      command_options = ["-p #{options[:port]}", "-o UserKnownHostsFile=/dev/null",
                         "-o StrictHostKeyChecking=no", "-o IdentitiesOnly=yes",
                         "-o LogLevel=ERROR"]
      command_options << "-i #{options[:private_key_path]}" if !plain_mode
      command_options << "-o ForwardAgent=yes" if ssh_info[:forward_agent]

      if ssh_info[:forward_x11]
        # Both are required so that no warnings are shown regarding X11
        command_options << "-o ForwardX11=yes"
        command_options << "-o ForwardX11Trusted=yes"
      end

      host_string = options[:host]
      host_string = "#{options[:username]}@#{host_string}" if !plain_mode
      command = "ssh #{command_options.join(" ")} #{host_string}".strip
      @logger.info("Invoking SSH: #{command}")
      safe_exec(command)
    end

    # Checks the file permissions for a private key, resetting them
    # if needed.
    def check_key_permissions(key_path)
      # Windows systems don't have this issue
      return if Util::Platform.windows?

      @logger.debug("Checking key permissions: #{key_path}")
      stat = File.stat(key_path)

      if stat.owned? && Util::FileMode.from_octal(stat.mode) != "600"
        @logger.info("Attempting to correct key permissions to 0600")
        File.chmod(0600, key_path)

        if Util::FileMode.from_octal(stat.mode) != "600"
          raise Errors::SSHKeyBadPermissions, :key_path => key_path
        end
      end
    rescue Errno::EPERM
      # This shouldn't happen since we verified we own the file, but
      # it is possible in theory, so we raise an error.
      raise Errors::SSHKeyBadPermissions, :key_path => key_path
    end
  end
end
