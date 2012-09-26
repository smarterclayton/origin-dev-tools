#!/usr/bin/env ruby

$: << File.expand_path(File.dirname(__FILE__))

require 'rubygems'
require 'thor'
require 'fileutils'
require 'lib/openshift'
require 'pp'
require 'yaml'

include FileUtils

module StickShift
  class Builder < Thor
    include OpenShift::BuilderHelper

    no_tasks do
      def ssh_user
        return "root"
      end

      def post_launch_setup(hostname)
        # Child classes can override, if required
      end
    end

    desc "build NAME BUILD_NUM", "Build a new devenv AMI with the given NAME"
    method_option :register, :type => :boolean, :desc => "Register the instance"
    method_option :terminate, :type => :boolean, :desc => "Terminate the instance on exit"
    method_option :use_stage_repo, :type => :boolean, :desc => "Build instance off the stage repository"
    method_option :use_test_repo, :type => :boolean, :desc => "Build instance off the test yum repository"
    method_option :reboot, :type => :boolean, :desc => "Reboot the instance after updating"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :official, :type => :boolean, :desc => "For official use.  Send emails, etc."
    method_option :exclude_broker, :type => :boolean, :desc => "Exclude broker tests"
    method_option :exclude_runtime, :type => :boolean, :desc => "Exclude runtime tests"
    method_option :exclude_site, :type => :boolean, :desc => "Exclude site tests"
    method_option :exclude_rhc, :type => :boolean, :desc => "Exclude rhc tests"
    method_option :include_web, :type => :boolean, :desc => "Include running Selenium tests"
    method_option :include_coverage, :type => :boolean, :desc => "Include coverage analysis on unit tests"
    method_option :include_extended, :required => false, :desc => "Include extended tests"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    method_option :build_clean_ami, :type => :boolean, :desc => "Indicates whether to start from a base RHEL image"
    method_option :install_from_source, :type => :boolean, :desc => "Indicates whether to build based off origin/master"
    method_option :install_from_local_source, :type => :boolean, :desc => "Indicates whether to build based on your local source"
    method_option :install_required_packages, :type => :boolean, :desc => "Create an instance with all the packages required by OpenShift"
    method_option :skip_verify, :type => :boolean, :desc => "Skip running tests to verify the build"
    method_option :instance_type, :required => false, :desc => "Amazon machine type override (default c1.medium)"
    method_option :extra_rpm_dir, :required => false, :dessc => "Directory containing extra rpms to be installed"
    def build(name, build_num)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR

      # Override the machine type to launch if necessary
      $amz_options[:instance_type] = options[:instance_type] if options[:instance_type]
  
      # Establish a new connection
      conn = connect(options.region)
  
      image = nil
      if options.install_required_packages?
        # Create a new builder instance
        if (options.region?nil)
          image = conn.images[AMI["us-east-1"]]
        elsif AMI[options.region].nil?
          puts "No AMI specified for region:" + options.region
          exit 1
        else
          image = conn.images[AMI[options.region]]
        end
      elsif options.build_clean_ami? || options.install_from_source? || options.install_from_local_source?
        # Get the latest devenv base image and create a new instance
        if options.use_stage_repo?
          filter = DEVENV_STAGE_BASE_WILDCARD
        else
          filter = DEVENV_BASE_WILDCARD
        end
        image = get_latest_ami(conn, filter)
      else
        # Get the latest devenv clean image and create a new instance
        if options.use_stage_repo?
          filter = DEVENV_STAGE_CLEAN_WILDCARD
        else
          filter = DEVENV_CLEAN_WILDCARD
        end
        image = get_latest_ami(conn, filter)
      end

      build_impl(name, build_num, image, conn, options)
    end

    desc "update", "Update current instance by installing RPMs from local git tree"
    method_option :include_stale, :type => :boolean, :desc => "Include packages that have been tagged but not synced to the repo"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    def update
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR
      update_impl(options)
    end

    desc "sync NAME", "Synchronize a local git repo with a remote DevEnv instance.  NAME should be ssh resolvable."
    method_option :tag, :type => :boolean, :desc => "NAME is an Amazon tag"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :skip_build, :type => :boolean, :desc => "Indicator to skip the rpm build/install"
    method_option :clean_metadata, :type => :boolean, :desc => "Cleans metadata before running yum commands"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    def sync(name)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR
      sync_impl(name, options)
    end

    desc "terminate TAG", "Terminates the instance with the specified tag"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    def terminate(tag)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR
      conn = connect(options.region)
      instance = find_instance(conn, tag, true, false, ssh_user)
      terminate_instance(instance, true) if instance
    end

    desc "launch NAME", "Launches the latest DevEnv instance, tagging with NAME"
    method_option :verifier, :type => :boolean, :desc => "Add verifier functionality (private IP setup and local tests)"
    method_option :use_stage_image, :type => :boolean, :desc => "Launch a stage DevEnv image"
    method_option :use_clean_image, :type => :boolean, :desc => "Launch a clean DevEnv image"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :express_server, :type => :boolean, :desc => "Set as express server in express.conf and leave on public_ip"
    method_option :ssh_config_verifier, :type => :boolean, :desc => "Set as verifier in .ssh/config"
    method_option :instance_type, :required => false, :desc => "Amazon machine type override (default '#{TYPE}')"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    method_option :image_name, :required => false, :desc => "AMI ID or DEVENV name to launch"
    def launch(name)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR

      ami = choose_ami_for_launch(options)

      # Override the machine type to launch if necessary
      $amz_options[:instance_type] = options[:instance_type] if options[:instance_type]

      if ami.nil?
        puts "No image name '#{options[:image_name]}' found!"
        exit(1)
      else
        puts "Launching latest instance #{ami.id} - #{ami.name}"
      end

      instance = launch_instance(ami, name, 1, ssh_user)
      hostname = instance.dns_name
      puts "Done"
      puts "Hostname: #{hostname}"

      puts "Sleeping for 30 seconds to let node stabilize..."
      sleep 30
      puts "Done"

      update_facts_impl(hostname)
      post_launch_setup(hostname)
      setup_verifier(hostname) if options.verifier?

      validate_instance(hostname, 4)

      update_api_file(instance) if options.ssh_config_verifier?
      update_ssh_config_verifier(instance) if options.ssh_config_verifier?
      update_express_server(instance) if options.express_server?

      home_dir=File.join(ENV['HOME'], '.openshiftdev/home.d')
      if File.exists?(home_dir)
        Dir.glob(File.join(home_dir, '???*'), File::FNM_DOTMATCH).each {|file|
          puts "Installing ~/#{File.basename(file)}"
          scp_to(hostname, file, "~/", File.stat(file).mode, 10, ssh_user)
        }
      end

      puts "Public IP:       #{instance.public_ip_address}"
      puts "Public Hostname: #{hostname}"
      puts "Site URL:        https://#{hostname}"
      puts "Done"
    end

    desc "test TAG", "Runs the tests on a tagged instance and downloads the results"
    method_option :terminate, :type => :boolean, :desc => "Terminate the instance when finished"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :official, :type => :boolean, :desc => "For official use.  Send emails, etc."
    method_option :exclude_broker, :type => :boolean, :desc => "Exclude broker tests"
    method_option :exclude_runtime, :type => :boolean, :desc => "Exclude runtime tests"
    method_option :exclude_site, :type => :boolean, :desc => "Exclude site tests"
    method_option :exclude_rhc, :type => :boolean, :desc => "Exclude rhc tests"
    method_option :include_cucumber, :required => false, :desc => "Include a specific cucumber test (verify, internal, node, api, etc)"
    method_option :include_coverage, :type => :boolean, :desc => "Include coverage analysis on unit tests"
    method_option :include_extended, :required => false, :desc => "Include extended tests"
    method_option :disable_charlie, :type => :boolean, :desc=> "Disable idle shutdown timer on dev instance (charlie)"
    method_option :mcollective_logs, :type => :boolean, :desc=> "Don't allow mcollective logs to be deleted on rotation"
    method_option :profile_broker, :type => :boolean, :desc=> "Enable profiling code on broker"
    method_option :include_web, :type => :boolean, :desc => "Include running Selenium tests"
    method_option :sauce_username, :required => false, :desc => "Sauce Labs username (default '#{SAUCE_USER}')"
    method_option :sauce_access_key, :required => false, :desc => "Sauce Labs access key (default '#{SAUCE_SECRET}')"
    method_option :sauce_overage, :type => :boolean, :desc => "Run Sauce Labs tests even if we are over our monthly minute quota"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    def test(tag)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR

      conn = connect(options.region)
      instance = find_instance(conn, tag, true, true, ssh_user)
      hostname = instance.dns_name

      test_impl(tag, hostname, instance, conn, options)
    end

    desc "sanity_check TAG", "Runs a set of sanity check tests on a tagged instance"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    method_option :region, :required => false, :desc => "Amazon region override (default us-east-1)"
    def sanity_check(tag)
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR

      conn = connect(options.region)
      instance = find_instance(conn, tag, true, true, ssh_user)
      hostname = instance.dns_name

      sanity_check_impl(tag, hostname, instance, conn, options)
    end

    desc "install_local_client", "Builds and installs the local client rpm (uses sudo)"
    method_option :verbose, :type => :boolean, :desc => "Enable verbose logging"
    def install_local_client
      options.verbose? ? @@log.level = Logger::DEBUG : @@log.level = Logger::ERROR

      if File.exists?('../rhc')
        inside('../rhc') do
          temp_commit

          puts "building rhc..."
          `tito build --rpm --test`
          puts "installing rhc..."
          `sudo rpm -Uvh --force /tmp/tito/noarch/rhc-*; rm -rf /tmp/tito; mkdir -p /tmp/tito`

          reset_temp_commit

          puts "Done"
        end
      else
        puts "Couldn't find ../rhc."
      end
    end

    no_tasks do
      def choose_ami_for_launch(options)
        # Get the latest devenv image and create a new instance
        conn = connect(options.region)
        filter = choose_filter_for_launch_ami(options)
        if options[:image_name]
          filter = options[:image_name]
          ami = get_specific_ami(conn, filter)
        else
          ami = get_latest_ami(conn, filter)
        end
        ami
      end

      def choose_filter_for_launch_ami(options)
        if options.use_stage_image?
          filter = DEVENV_STAGE_WILDCARD
        elsif options.use_clean_image?
          filter = DEVENV_CLEAN_WILDCARD
        else
          filter = DEVENV_WILDCARD
        end
        filter
      end
    end #no_tasks
  end #class
end #module
