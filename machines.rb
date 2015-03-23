# coding: utf-8
require 'chef/provisioning'

with_driver 'maas'
Chef::Config.knife[:maas_site] = 'http://10.0.1.138/MAAS/'
Chef::Config.knife[:maas_api_key] = 'zmY4nQtfK64K2EmfPP:RkDgWs8DfBvnfnKkG6:VBnvv3ySnzd2TgJ7MGSRkUX84npnY9Jg'

machine 'node1' do
  recipe 'base'
  chef_environment '_default'
  machine_options({
                      acquire_criteria: { zone: zone2 },
                        start_options: { distro_series: 'ubuntu-14' }
                  })
  converge true
end
