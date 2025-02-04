#
# Cookbook:: filebeat
# Resource:: filebeat_install
#

resource_name :filebeat_install

property :version, String, default: '7.6.2'
property :release, String, default: '1'
property :setup_repo, [true, false], default: true
property :ignore_package_version, [true, false], default: false
property :service_name, String, default: 'filebeat'
property :notify_restart, [true, false], default: true
property :disable_service, [true, false], default: false
property :delete_prospectors_dir, [true, false], default: false
property :conf_dir, [String, NilClass]
property :prospectors_dir, [String, NilClass]
property :log_dir, [String, NilClass]
property :windows_package_url, String, default: 'auto'
property :windows_base_dir, String, default: 'C:/opt/filebeat'
property :apt_options, String, default: "-o Dpkg::Options::='--force-confnew' --force-yes"
property :elastic_repo_options, Hash, default: {}

default_action :create

action :create do
  new_resource.conf_dir = new_resource.conf_dir || default_config_dir(new_resource.version, new_resource.windows_base_dir)
  new_resource.prospectors_dir = new_resource.prospectors_dir || default_prospectors_dir(new_resource.conf_dir)
  new_resource.log_dir = new_resource.log_dir || default_log_dir(new_resource.conf_dir)
  version_string = platform_family?('fedora', 'rhel', 'amazon')  || node['platform'] == 'xcp' ? "#{new_resource.version}-#{new_resource.release}" : new_resource.version

  with_run_context(:root) do
    edit_resource(:service, new_resource.service_name) do
      action :nothing
    end
  end

  ## install filebeat MacOS
  if platform?('mac_os_x')
    include_recipe 'homebrew'

    # The brew package does not create the 'filebeat' directory in '/etc'.
    directory '/etc/filebeat' do
      action :create
      mode '755'
      owner 'root'
      group 'wheel'
    end

    # Need to drop the .plist file before the package install as brew will try to start the service immediately.
    cookbook_file '/Library/LaunchDaemons/co.elastic.filebeat.plist' do
      action :create
      content 'co.elastic.filebeat.plist'
    end

    # This install depends on brew for the installation of filebeat.
    package 'filebeat' do
      action :install
    end
  end

  ## install filebeat windows
  if platform?('windows')
    package_url = win_package_url(new_resource.version, new_resource.windows_package_url)
    package_file = ::File.join(Chef::Config[:file_cache_path], ::File.basename(package_url))

    remote_file 'filebeat_package_file' do
      path package_file
      source package_url
      not_if { ::File.exist?(package_file) }
    end

    directory new_resource.windows_base_dir do
      recursive true
      action :create
    end

    windows_zipfile new_resource.windows_base_dir do
      source package_file
      action :unzip
      not_if { ::File.exist?(new_resource.conf_dir + '/install-service-filebeat.ps1') }
      notifies :run, 'powershell_script[install filebeat as service]', :immediately
    end

    powershell_script 'install filebeat as service' do
      code "& '#{new_resource.conf_dir}/install-service-filebeat.ps1'"
      action :nothing
    end
  end

  ## install filebeat yum/apt
  if platform_family?('fedora', 'rhel', 'amazon', 'debian')
    # setup yum/apt repository
    elastic_repo_opts = new_resource.elastic_repo_options.dup
    elastic_repo_opts['version'] = new_resource.version
    elastic_repo 'default' do
      elastic_repo_opts.each do |key, value|
        send(key, value) unless value.nil?
      end
      only_if { new_resource.setup_repo }
    end

    # pin yum/apt version
    case node['platform_family']
    when 'debian'
      unless new_resource.ignore_package_version # ~FC023
        apt_preference 'filebeat' do
          pin "version #{new_resource.version}"
          pin_priority '700'
        end
      end
    when 'fedora', 'rhel', 'amazon'
      include_recipe 'yum-plugin-versionlock::default'

      unless new_resource.ignore_package_version # ~FC023
        yum_version_lock 'filebeat' do
          version new_resource.version
          release new_resource.release
          action :update
        end
      end
    end

    package 'filebeat' do # ~FC009
      version version_string unless new_resource.ignore_package_version
      options new_resource.apt_options if new_resource.apt_options && platform_family?('debian')
      notifies :restart, "service[#{new_resource.service_name}]" if new_resource.notify_restart && !new_resource.disable_service
      if platform_family?('rhel', 'amazon')
        flush_cache(:before => true)
        allow_downgrade true
      end
    end
    else
    if node['platform'] == 'xcp'

      old_platform = node['platform']
      node.override['platform'] = "centos" 
      
      old_platform_family = node['platform_family']
      node.override['platform_family'] = "rhel" 
      
      old_platform_version = node['platform_version']
      node.override['platform_version'] = "7.9.2009" 


      # setup yum/apt repository
      elastic_repo_opts = new_resource.elastic_repo_options.dup
      elastic_repo_opts['version'] = new_resource.version
      elastic_repo 'default' do
        elastic_repo_opts.each do |key, value|
          send(key, value) unless value.nil?
        end
        only_if { new_resource.setup_repo }
      end

      include_recipe 'yum-plugin-versionlock::default'

      edit_resource!(:package, 'yum-plugin-versionlock') do
        action :nothing
      end

      yum_package 'yum-plugin-versionlock'

      unless new_resource.ignore_package_version # ~FC023
        yum_version_lock 'filebeat' do
          version new_resource.version
          release new_resource.release
          action :update
        end
      end

      yum_package 'filebeat' do # ~FC009
        version version_string unless new_resource.ignore_package_version
        options new_resource.apt_options if new_resource.apt_options && node['platform_family'] == 'debian'
        notifies :restart, "service[#{new_resource.service_name}]" if new_resource.notify_restart && !new_resource.disable_service
        flush_cache(:before => true)
        allow_downgrade true
      end

    end
  end

  directory new_resource.log_dir do
    mode '755'
  end

  prospectors_dir_action = new_resource.delete_prospectors_dir ? %i(delete create) : %i(create)

  directory new_resource.prospectors_dir do
    recursive true
    action prospectors_dir_action
  end
end

action :delete do
  with_run_context(:root) do
    edit_resource(:service, new_resource.service_name) do
      action :stop, :disable
    end
  end

  package 'filebeat' do
    action :remove
  end

  directory '/etc/filebeat' do
    action :delete
    recursive true
  end

  directory '/var/log/filebeat' do
    action :delete
    recursive true
  end
end

action_class do
  include ::Filebeat::Helpers
end
