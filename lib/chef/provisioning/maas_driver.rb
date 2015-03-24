require 'chef/provisioning/driver'
require 'oauth'
require 'oauth/signature/plaintext'
require 'chef/json_compat'
require 'chef/knife'
require 'readline'

module Chef::Provisioning
  class MAASDriver < Chef::Provisioning::Driver

    def self.from_url(maas_url, config)
      MAASDriver.new(maas_url, config)
    end

    def self.canonicalize_url(url, config)
      scheme, maas_url = url.split(':' , 2)
      if maas_url.nil? || maas_url == ''
        maas_url = config[:knife][:maas_site]
      end
      "maas:" + maas_url
    end

    def initialize(maas_url, config)
      super(maas_url, config)
    end

    def maas_url
      scheme, maas_url = driver_url.split(':', 2)
      maas_url
    end

    def prepare_access_token(oauth_token, oauth_token_secret, consumer_key, consumer_secret)

      site = File.join(maas_url,"api/1.0/")

      consumer = OAuth::Consumer.new( consumer_key,
                                      consumer_secret,
                                      {
                                        :site => site,
                                        :scheme => :header,
                                        :signature_method => "PLAINTEXT"
                                      })

      access_token = OAuth::AccessToken.new( consumer,
                                             oauth_token,
                                             oauth_token_secret
                                           )
      return access_token
    end

    def access_token
      maas_key = "#{locate_config_value(:maas_api_key)}"
      customer_key = maas_key.split(":")[0]
      customer_secret = ""
      token_key = maas_key.split(":")[1]
      token_secret = maas_key.split(":")[2]
      prepare_access_token(token_key, token_secret, customer_key, customer_secret)
    end

    def locate_config_value(key)
      key = key.to_sym
      config[:knife][key]
    end

    def post(path, op, options = nil)
      path = File.join('/', path, '/')
      request_options = { 'op' => op }
      request_options.merge!(options) if options
      response = access_token.request(:post, path, request_options)
      JSON.parse(response.body)
    end

    def get(path, op = nil, options = nil)
      path = File.join('/', path, '/')
      request_options = {}
      request_options['op'] = op if op
      request_options.merge!(options) if options
      response = access_token.request(:get, path, request_options)
      JSON.parse(response.body)
    end

    def allocate_machine(action_handler, machine_spec, machine_options)

      # If we don't have an associated node, acquire one.
      if !machine_spec.reference || !machine_spec.reference['system_id']
        action_handler.perform_action "Acquiring server #{machine_spec.name} with options #{machine_options}" do

          node = post("/nodes", :acquire, machine_options[:deploy_options])

          machine_spec.reference = {
            'driver_url' => driver_url,
            'driver_version' => MAAS_DRIVER_VERSION,
            'system_id' => node['system_id']
          }

          machine_spec.save(action_handler)
        end

      else
        # If we have a system_id, but it does not exist in MAAS or is not in an acquired state, report that to the user.
        node = get("/nodes/#{machine_spec.reference['system_id']}")
        if !node
          raise "Node with ID #{machine_spec.reference['system_id']} does not exist!"
        end
        if !node['owner']
          raise "Node with ID #{machine_spec.reference['system_id']} is not owned by anyone anymore!"
        end
      end

      print(".")
      sleep 30
      print(".")

      # If the node has not been deployed (if it is in READY state), we get it up and deployed
      node = get("/nodes/#{machine_spec.reference['system_id']}")
      if node['substatus'] == 10
        post("/nodes/#{machine_spec.reference['system_id']}", :start)
      end
    end

    def ready_machine(action_handler, machine_spec, machine_options)

      print(".")
      sleep 30
      print(".")

      system_id = machine_spec.reference['system_id']
      node = get("/nodes/#{machine_spec.reference['system_id']}")
      # If the machine is in a stopped state, we start it. TODO
      if node['substatus'] == 10
        post("/nodes/#{machine_spec.reference['system_id']}", :start)
      end

      # Wait for the machine to be started / deployed / whatever
      system_info = get("/nodes/#{machine_spec.reference['system_id']}")

      until system_info['netboot'] == false && system_info['power_state'] == 'on' do
        print(".")
        sleep @initial_sleep_delay ||= 10
        system_info = get("/nodes/#{system_id}/")
      end

      bootstrap_ip_address = system_info["ip_addresses"][0]

      require 'pry'; binding.pry
      # Return the Machine object
      machine_for(machine_spec, machine_options)
    end

    def machine_for(machine_spec, machine_options, instance = nil)
      instance ||= instance_for(machine_spec)

      if !instance
        raise "Instance for node #{machine_spec.name} has not been created!"
      end

      if machine_spec.reference['is_windows']
        Chef::Provisioning::Machine::WindowsMachine.new(machine_spec, transport_for(machine_spec, machine_options, instance), convergence_strategy_for(machine_spec, machine_options))
      else
        Chef::Provisioning::Machine::UnixMachine.new(machine_spec, transport_for(machine_spec, machine_options, instance), convergence_strategy_for(machine_spec, machine_options))
      end
    end

    def transport_for(machine_spec, machine_options, node)
      if machine_spec.reference['is_windows']
        create_winrm_transport(machine_spec, machine_options, node)
      else
        create_ssh_transport(machine_spec, machine_options, node)
      end
    end

    def create_ssh_transport(machine_spec, machine_options, node)
      ssh_options = ssh_options_for(machine_spec, machine_options)
      username = node['owner'] || machine_options[:ssh_username] || default_ssh_username
      if machine_options.has_key?(:ssh_username) && machine_options[:ssh_username] != machine_spec.reference['ssh_username']
        Chef::Log.warn("Server #{machine_spec.name} was created with SSH username #{machine_spec.reference['ssh_username']} and machine_options specifies username #{machine_options[:ssh_username]}.  Using #{machine_spec.reference['ssh_username']}.  Please edit the node and change the chef_provisioning.reference.ssh_username attribute if you want to change it.")
      end
      options = {}
      if machine_spec.reference[:sudo] || (!machine_spec.reference.has_key?(:sudo) && username != 'root')
        options[:prefix] = 'sudo '
      end

      remote_host = determine_remote_host(machine_spec)

      #Enable pty by default
      options[:ssh_pty_enable] = true
      options[:ssh_gateway] = machine_spec.reference['ssh_gateway'] if machine_spec.reference.has_key?('ssh_gateway')

      Chef::Provisioning::Transport::SSH.new(remote_host, username, ssh_options, options, config)
    end

    def ssh_options_for(machine_spec, machine_options, instance)
      result = {
        # TODO create a user known hosts file
        #          :user_known_hosts_file => vagrant_ssh_config['UserKnownHostsFile'],
        #          :paranoid => true,
        :auth_methods => [ 'publickey' ],
        :keys_only => true
      }.merge(machine_options[:ssh_options] || {})
      if instance.respond_to?(:private_key) && instance.private_key
        result[:key_data] = [ instance.private_key ]
      elsif instance.respond_to?(:key_name) && instance.key_name
        key = get_private_key(instance.key_name)
        unless key
          raise "Server has key name '#{instance.key_name}', but the corresponding private key was not found locally.  Check if the key is in Chef::Config.private_key_paths: #{Chef::Config.private_key_paths.join(', ')}"
        end
        result[:key_data] = [ key ]
      elsif machine_spec.reference['key_name']
        key = get_private_key(machine_spec.reference['key_name'])
        unless key
          raise "Server was created with key name '#{machine_spec.reference['key_name']}', but the corresponding private key was not found locally.  Check if the key is in Chef::Config.private_key_paths: #{Chef::Config.private_key_paths.join(', ')}"
        end
        result[:key_data] = [ key ]
      elsif machine_options[:bootstrap_options] && machine_options[:bootstrap_options][:key_path]
        result[:key_data] = [ IO.read(machine_options[:bootstrap_options][:key_path]) ]
      elsif machine_options[:bootstrap_options] && machine_options[:bootstrap_options][:key_name]
        result[:key_data] = [ get_private_key(machine_options[:bootstrap_options][:key_name]) ]
      else
        # TODO make a way to suggest other keys to try ...
        raise "No key found to connect to #{machine_spec.name} (#{machine_spec.reference.inspect})!"
      end
      result
    end

    def destroy_machine(action_handler, machine_spec, machine_options)
      if machine_spec.reference
        server_id = machine_spec.reference['server_id']
        action_handler.perform_action "Release machine #{server_id}" do
          post("/nodes/#{machine_spec.reference['system_id']}/", :release)
          machine_spec.reference = nil
          machine_spec.delete(action_handler)
        end
      end
    end



  end
end
