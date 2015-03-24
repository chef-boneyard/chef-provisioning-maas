require 'chef/provisioning'

with_driver 'maas'
Chef::Config.knife[:maas_site] = 'http://10.0.1.138/MAAS/'
Chef::Config.knife[:maas_api_key] = 'zmY4nQtfK64K2EmfPP:RkDgWs8DfBvnfnKkG6:VBnvv3ySnzd2TgJ7MGSRkUX84npnY9Jg'

machine_batch do
  machines search(:node, '*:*').map(&:name)
  action :destroy
end
