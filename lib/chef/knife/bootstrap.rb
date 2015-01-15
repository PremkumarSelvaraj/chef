#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2010 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'
require 'chef/knife/data_bag_secret_options'
require 'erubis'

class Chef
  class Knife
    class Bootstrap < Knife
      include DataBagSecretOptions

      deps do
        require 'chef/knife/core/bootstrap_context'
        require 'chef/json_compat'
        require 'chef/api_client/registration'
        require 'chef/node'
        require 'tempfile'
        require 'highline'
        require 'net/ssh'
        require 'net/ssh/multi'
        require 'chef/knife/ssh'
        Chef::Knife::Ssh.load_deps
      end

      banner "knife bootstrap FQDN (options)"

      option :ssh_user,
        :short => "-x USERNAME",
        :long => "--ssh-user USERNAME",
        :description => "The ssh username",
        :default => "root"

      option :ssh_password,
        :short => "-P PASSWORD",
        :long => "--ssh-password PASSWORD",
        :description => "The ssh password"

      option :ssh_port,
        :short => "-p PORT",
        :long => "--ssh-port PORT",
        :description => "The ssh port"

      option :ssh_gateway,
        :short => "-G GATEWAY",
        :long => "--ssh-gateway GATEWAY",
        :description => "The ssh gateway"

      option :forward_agent,
        :short => "-A",
        :long => "--forward-agent",
        :description => "Enable SSH agent forwarding",
        :boolean => true

      option :identity_file,
        :short => "-i IDENTITY_FILE",
        :long => "--identity-file IDENTITY_FILE",
        :description => "The SSH identity file used for authentication"

      option :chef_node_name,
        :short => "-N NAME",
        :long => "--node-name NAME",
        :description => "The Chef node name for your new node"

      option :prerelease,
        :long => "--prerelease",
        :description => "Install the pre-release chef gems"

      option :bootstrap_version,
        :long => "--bootstrap-version VERSION",
        :description => "The version of Chef to install"

      option :bootstrap_proxy,
        :long => "--bootstrap-proxy PROXY_URL",
        :description => "The proxy server for the node being bootstrapped"

      option :bootstrap_no_proxy,
        :long => "--bootstrap-no-proxy [NO_PROXY_URL|NO_PROXY_IP]",
        :description => "Do not proxy locations for the node being bootstrapped; this option is used internally by Opscode"

      # DEPR: Remove this option in Chef 13
      option :distro,
        :short => "-d DISTRO",
        :long => "--distro DISTRO",
        :description => "Bootstrap a distro using a template. [DEPRECATED] Use -t / --bootstrap-template option instead.",
        :proc        => Proc.new { |v|
          Chef::Log.warn("[DEPRECATED] -d / --distro option is deprecated. Use -t / --bootstrap-template option instead.")
          v
        }

      option :bootstrap_template,
        :short => "-t TEMPLATE",
        :long => "--bootstrap-template TEMPLATE",
        :description => "Bootstrap Chef using a built-in or custom template. Set to the full path of an erb template or use one of the built-in templates."

      option :use_sudo,
        :long => "--sudo",
        :description => "Execute the bootstrap via sudo",
        :boolean => true

      option :use_sudo_password,
        :long => "--use-sudo-password",
        :description => "Execute the bootstrap via sudo with password",
        :boolean => false

      # DEPR: Remove this option in Chef 13
      option :template_file,
        :long => "--template-file TEMPLATE",
        :description => "Full path to location of template to use. [DEPRECATED] Use -t / --bootstrap-template option instead.",
        :proc        => Proc.new { |v|
          Chef::Log.warn("[DEPRECATED] --template-file option is deprecated. Use -t / --bootstrap-template option instead.")
          v
        }

      option :run_list,
        :short => "-r RUN_LIST",
        :long => "--run-list RUN_LIST",
        :description => "Comma separated list of roles/recipes to apply",
        :proc => lambda { |o| o.split(/[\s,]+/) },
        :default => []

      option :first_boot_attributes,
        :short => "-j JSON_ATTRIBS",
        :long => "--json-attributes",
        :description => "A JSON string to be added to the first run of chef-client",
        :proc => lambda { |o| Chef::JSONCompat.parse(o) },
        :default => {}

      option :host_key_verify,
        :long => "--[no-]host-key-verify",
        :description => "Verify host key, enabled by default.",
        :boolean => true,
        :default => true

      option :hint,
        :long => "--hint HINT_NAME[=HINT_FILE]",
        :description => "Specify Ohai Hint to be set on the bootstrap target.  Use multiple --hint options to specify multiple hints.",
        :proc => Proc.new { |h|
          Chef::Config[:knife][:hints] ||= Hash.new
          name, path = h.split("=")
          Chef::Config[:knife][:hints][name] = path ? Chef::JSONCompat.parse(::File.read(path)) : Hash.new
        }

      option :bootstrap_url,
        :long        => "--bootstrap-url URL",
        :description => "URL to a custom installation script"

      option :bootstrap_install_command,
        :long        => "--bootstrap-install-command COMMANDS",
        :description => "Custom command to install chef-client"

      option :bootstrap_wget_options,
        :long        => "--bootstrap-wget-options OPTIONS",
        :description => "Add options to wget when installing chef-client"

      option :bootstrap_curl_options,
        :long        => "--bootstrap-curl-options OPTIONS",
        :description => "Add options to curl when install chef-client"

      option :node_ssl_verify_mode,
        :long        => "--node-ssl-verify-mode [peer|none]",
        :description => "Whether or not to verify the SSL cert for all HTTPS requests.",
        :proc        => Proc.new { |v|
          valid_values = ["none", "peer"]
          unless valid_values.include?(v)
            raise "Invalid value '#{v}' for --node-ssl-verify-mode. Valid values are: #{valid_values.join(", ")}"
          end
        }

      option :node_verify_api_cert,
        :long        => "--[no-]node-verify-api-cert",
        :description => "Verify the SSL cert for HTTPS requests to the Chef server API.",
        :boolean     => true

      option :vault_file,
        :short       => '-L VAULT_FILE',
        :long        => '--vault-file',
        :description => 'A JSON file with a list of vault',
        :proc        => lambda { |l| Chef::JSONCompat.from_json(::File.read(l)) }

      option :vault_list,
        :short       => '-l VAULT_LIST',
        :long        => '--vault-list VAULT_LIST',
        :description => 'A JSON string with the vault to be updated',
        :proc        => lambda { |v| Chef::JSONCompat.from_json(v) }

      option :bootstrap_uses_validator,
        :long        => "--[no-]bootstrap-uses-validator",
        :description => "Force bootstrap to use validation.pem instead of users client key",
        :boolean     => true,
        :default     => false

      option :bootstrap_overwrite_node,
        :long        => "--[no-]bootstrap-overwrite-node",
        :description => "When bootstrapping (without validation.pem) overwrite existing node",
        :boolean     => true,
        :default     => false

      def default_bootstrap_template
        "chef-full"
      end

      def normalized_run_list
        case config[:run_list]
        when nil
          []
        when String
          config[:run_list].split(/\s*,\s*/)
        when Array
          config[:run_list]
        end
      end

      def node_exists?
        return @node_exists unless @node_exists.nil?
        @node_exists =
          begin
          rest.get_rest("node/#{node_name}")
          true
#        rescue # Something
#          false
        end
      end

      def client_exists?
        return @client_exists unless @client_exists.nil?
        @client_exists =
        begin
          rest.get_rest("client/#{node_name}")
          true
#        rescue  # Something
#          false
        end
      end

      def register_client
        tmpdir = Dir.mktmpdir
        client_path = File.join(tmpdir, "#{node_name}.pem")
        overwrite_node = config[:bootstrap_overwrite_node]

        if node_exists?
          if client_exists?
            if !overwrite_node
              # default:  protect users from overwriting properly created node/client pairs
              ui.fatal("Node and client already exist and bootstrap_overwrite_node is false")
            else
              # chainsaw mode:  if you typo the wong thing, we will delete your production servers
              ui.info("Will overwrite existing node and client because bootstrap_overwrite_node is true")
            end
          else
            # most positive action:  assume you've precreated node data
            ui.info("Node exists, but client does not, assuming pre-created node data")
          end
        else
          if client_exists?
            # most positive action:  you forgot to delete a client, so clean it up
            ui.info("Node does not exist, but client does, will delete and recreate old client")
          else
            ui.info("Will create new node and client")
          end
        end

        ui.info("Creating client for #{node_name} on server#{ "(replacing existing client)" if client_exists? }")

        Chef::ApiClient::Registration.new(node_name, client_path, http_api: rest).run

        first_boot_attributes = config[:first_boot_attributes]
        new_node = Chef::Node.new
        new_node.name(node_name)
        new_node.run_list(normalized_run_list)
        new_node.normal_attrs = first_boot_attribute if first_boot_attributes
        new_node.environment(config[:environment]) if config[:environment]

        client_rest = Chef::REST.new(
          Chef::Config.chef_server_url,
          node_name,
          client_path,
        )

        client_rest.post_rest("nodes/", new_node)

        #          else
        #            ui.fatal("Something went wrong! Unable to find the Node: Please delete the Client and retry.")
        #            exit 2
        #          end
        #        elsif client.empty?
        #          ui.fatal("Something went wrong! Unable to find the Client: Please delete the Node and retry.")
        #          exit 3
        #        else
        #          ui.info("Node already exist - skipping registration")
        #        end
      end

      def bootstrap_template
        # The order here is important. We want to check if we have the new Chef 12 option is set first.
        # Knife cloud plugins unfortunately all set a default option for the :distro so it should be at
        # the end.
        config[:bootstrap_template] || config[:template_file] || config[:distro] || default_bootstrap_template
      end

      def find_template
        template = bootstrap_template

        # Use the template directly if it's a path to an actual file
        if File.exists?(template)
          Chef::Log.debug("Using the specified bootstrap template: #{File.dirname(template)}")
          return template
        end

        # Otherwise search the template directories until we find the right one
        bootstrap_files = []
        bootstrap_files << File.join(File.dirname(__FILE__), 'bootstrap', "#{template}.erb")
        bootstrap_files << File.join(Knife.chef_config_dir, "bootstrap", "#{template}.erb") if Chef::Knife.chef_config_dir
        bootstrap_files << File.join(ENV['HOME'], '.chef', 'bootstrap', "#{template}.erb") if ENV['HOME']
        bootstrap_files << Gem.find_files(File.join("chef","knife","bootstrap","#{template}.erb"))
        bootstrap_files.flatten!

        template_file = Array(bootstrap_files).find do |bootstrap_template|
          Chef::Log.debug("Looking for bootstrap template in #{File.dirname(bootstrap_template)}")
          File.exists?(bootstrap_template)
        end

        unless template_file
          ui.info("Can not find bootstrap definition for #{template}")
          raise Errno::ENOENT
        end

        Chef::Log.debug("Found bootstrap template in #{File.dirname(template_file)}")

        template_file
      end

      def render_template
        template_file = find_template
        template = IO.read(template_file).chomp
        secret = encryption_secret_provided_ignore_encrypt_flag? ? read_secret : nil
        context = Knife::Core::BootstrapContext.new(config, config[:run_list], Chef::Config, secret)
        Erubis::Eruby.new(template).evaluate(context)
      end

      def node_name
        config[:chef_node_name]
      end

      def run
        validate_name_args!

        $stdout.sync = true

        if config[:vault_list] || config[:vault_file]
          ui.info("#{ui.color(connection_server_name, :bold)} Starting Pre-Bootstrap Process")
          config[:client_pem] = File.expand_path(File.join(File.dirname(__FILE__), 'keeper.pem'))

          ui.info("#{ui.color(connection_server_name, :bold)} Registering Node #{ui.color(node_name, :bold)}")
          register_client

          ui.info("#{ui.color(connection_server_name, :bold)} Waiting search node.. ") while wait_node

          ui.info("#{ui.color(connection_server_name, :bold)} Updating Chef Vault(s)")
          update_vault_list(config[:vault_list]) if config[:vault_list]
          de
          update_vault_list(config[:vault_file]) if config[:vault_file]
        end

        ui.info("Connecting to #{ui.color(connection_server_name, :bold)}")

        begin
          knife_ssh.run
        rescue Net::SSH::AuthenticationFailed
          if config[:ssh_password]
            raise
          else
            ui.info("Failed to authenticate #{config[:ssh_user]} - trying password auth")
            knife_ssh_with_password_auth.run
          end
        end
      end

      def validate_name_args!
        if connection_server_name.nil?
          ui.error("Must pass an FQDN or ip to bootstrap")
          exit 1
        elsif connection_server_name.first == "windows"
          ui.warn("Hostname containing 'windows' specified. Please install 'knife-windows' if you are attempting to bootstrap a Windows node via WinRM.")
        end
      end

      def connection_server_name
        Array(@name_args).first
      end

      def knife_ssh
        ssh = Chef::Knife::Ssh.new
        ssh.ui = ui
        ssh.name_args = [ connection_server_name, ssh_command ]
        ssh.config[:ssh_user] = config[:ssh_user]
        ssh.config[:ssh_password] = config[:ssh_password]
        ssh.config[:ssh_port] = config[:ssh_port]
        ssh.config[:ssh_gateway] = config[:ssh_gateway]
        ssh.config[:forward_agent] = config[:forward_agent]
        ssh.config[:identity_file] = config[:identity_file]
        ssh.config[:manual] = true
        ssh.config[:host_key_verify] = config[:host_key_verify]
        ssh.config[:on_error] = :raise
        ssh
      end

      def knife_ssh_with_password_auth
        ssh = knife_ssh
        ssh.config[:identity_file] = nil
        ssh.config[:ssh_password] = ssh.get_password
        ssh
      end

      def ssh_command
        command = render_template

        if config[:use_sudo]
          command = config[:use_sudo_password] ? "echo '#{config[:ssh_password]}' | sudo -S #{command}" : "sudo #{command}"
        end

        command
      end

      def update_vault_list(vault_list)
        vault_list.each do |vault, item|
          if item.is_a?(Array)
            item.each do |i|
              update_vault(vault, i)
            end
          else
            update_vault(vault, item)
          end
        end
      end

      def update_vault(vault, item)
        begin
          vault_item = ChefVault::Item.load(vault, item)
          # this is idiotic to call here, it searches for the node to get the client to set on the item -- and
          # we just created the node and the client, so why the hell do we need to wait for search?
          vault_item.clients("name:#{node_name}")
          vault_item.save
        rescue ChefVault::Exceptions::KeysNotFound,
          ChefVault::Exceptions::ItemNotFound

          raise ChefVault::Exceptions::ItemNotFound,
            "#{vault}/#{item} does not exist, "\
            "you might want to delete the node before retrying."
        end
      end
    end
  end
end
