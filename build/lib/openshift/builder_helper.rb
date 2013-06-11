#!/usr/bin/env ruby

require 'rubygems'
require 'thor'
require 'fileutils'
require 'pp'
require 'yaml'

include FileUtils

# we will need ssh with some different options for git clones
GIT_SSH_PATH=File.expand_path(File.dirname(__FILE__)) + "/ssh-override"

module OpenShift
  module BuilderHelper
    include Thor::Actions
    include OpenShift::Tito
    include OpenShift::SSH
    include OpenShift::Amazon

    @@SSH_TIMEOUT = 4800
    @@SSH_TIMEOUT_OVERRIDES = { "benchmark" => 172800 }

    # Get the hostname from a tag lookup or assume it's SSH accessible directly
    # Only look for a tag if the --tag option is specified
    def get_host_by_name_or_tag(name, options=nil, user="root")
      return name unless options && options.tag?
      
      instance = find_instance(connect(options.region), name, true, true, user)
      if not instance.nil?
        return instance.dns_name
      else
        puts "Unable to find instance with tag: #{name}"
        exit 1
      end
    end

    def build_and_install(package_name, build_dir, spec_file, options)
      remove_dir '/tmp/tito/'
      FileUtils.mkdir_p '/tmp/tito/'
      puts "Building in #{build_dir}"
      spec_file = File.expand_path(spec_file)
      inside(File.expand_path("#{build_dir}", File.dirname(File.dirname(File.dirname(File.dirname(__FILE__)))))) do
        # Build and install the RPM's locally
        unless run("tito build --rpm --test", :verbose => options.verbose?)
          package = Package.new(spec_file, File.dirname(spec_file))
          package_name = package.name
          ignore_packages = get_ignore_packages
          packages = get_packages
          required_packages_str = ''
          unless ignore_packages.include?(package_name)
            package.build_requires.each do |r_package|
              required_packages_str += " \\\"#{r_package.yum_name_with_version}\\\"" unless packages.include?(r_package.name)
            end
          end
          run("su -c \"yum install -y --skip-broken #{required_packages_str} 2>&1\"") unless required_packages_str.empty?

          if required_packages_str.empty? || !run("tito build --rpm --test", :verbose => options.verbose?)
            if options.retry_failure_with_tag
              # Tag to trick tito to build
              commit_id = `git log --pretty=format:%%H --max-count=1 %s" % .`
              spec_file_name = File.basename(spec_file)
              version = get_version(spec_file_name)
              next_version = next_tito_version(version, commit_id)
              puts "current spec file version #{version} next version #{next_version}"
              unless run("tito tag --accept-auto-changelog --use-version='#{next_version}'; tito build --rpm --test", :verbose => options.verbose?)
                FileUtils.rm_rf '/tmp/devenv/sync/'
                exit 1
              end
            else
              puts "Package #{package_name} failed to build."
            end
          end
        end
        Dir.glob('/tmp/tito/x86_64/*.rpm').each {|file|
          FileUtils.mkdir_p "/tmp/tito/noarch/"
          FileUtils.mv file, "/tmp/tito/noarch/"
        }
        unless run("rpm -Uvh --force /tmp/tito/noarch/*.rpm", :verbose => options.verbose?)
          unless run("rpm -e --justdb --nodeps #{package_name}; yum install -y /tmp/tito/noarch/*.rpm", :verbose => options.verbose?)
            FileUtils.rm_rf '/tmp/devenv/sync/'
            exit 1
          end
        end
        if build_dir =~ /\/cartridges\/openshift-origin-cartridge-(.*)/ || build_dir =~ /\/cartridges\/(.*)/
          short_cart_name = $1
          cart_install_dir = "/usr/libexec/openshift/cartridges/v2/#{short_cart_name}"
          if File.exists? cart_install_dir
            unless run("oo-admin-cartridge --action install --source #{cart_install_dir}", :verbose => options.verbose?)
              FileUtils.rm_rf '/tmp/devenv/sync/'
              exit 1
            end
          end
        end
      end
    end

    def update_remote_tests(hostname, branch=nil, repo_parent_dir="/root", user="root")
      puts "Updating remote tests..."
      git_archive_commands = ''
      SIBLING_REPOS.each do |repo_name, repo_dirs|
        repo_dir = "#{repo_parent_dir}/#{repo_name}-bare"
        git_archive_commands += "pushd #{repo_dir} > /dev/null; git archive --prefix openshift-test/#{::OPENSHIFT_ARCHIVE_DIR_MAP[repo_name] || ''} --format=tar #{branch ? branch : 'HEAD'} | (cd #{repo_parent_dir} && tar --warning=no-timestamp -xf -); popd > /dev/null; "
      end

      ssh(hostname, %{
set -e;
su -c \"rm -rf #{repo_parent_dir}/openshift-test\"
#{git_archive_commands}
su -c \"mkdir -p /tmp/rhc/junit\"
}, 60, false, 4, user)

      update_cucumber_tests(hostname, repo_parent_dir, user)
      puts "Done"
    end
    
    def scp_remote_tests(hostname, repo_parent_dir="/root", user="root")
      init_repos(hostname, true, nil, repo_parent_dir, user)
      sync_repos(hostname, repo_parent_dir, user)
      update_remote_tests(hostname, nil, repo_parent_dir, user)
    end
    
    def sync_repos(hostname, remote_repo_parent_dir="/root", sshuser="root")
      SIBLING_REPOS.each do |repo_name, repo_dirs|
        repo_dirs.each do |repo_dir|
          break if sync_sibling_repo(repo_name, repo_dir, hostname, remote_repo_parent_dir, sshuser)
        end
      end
    end

    def sync_repo(repo_name, hostname, remote_repo_parent_dir="/root", ssh_user="root", verbose=false)
      temp_commit

      begin

        # Get the current branch
        branch = get_branch

        puts "Synchronizing local changes from branch #{branch} for repo #{repo_name} from #{File.basename(FileUtils.pwd)}..."

        init_repos(hostname, false, repo_name, remote_repo_parent_dir, ssh_user)

        exitcode = run(<<-"SHELL", :verbose => verbose)
          #######
          # Start shell code
          export GIT_SSH=#{GIT_SSH_PATH}
          #{branch == 'origin/master' ? "git push -q #{ssh_user}@#{hostname}:#{remote_repo_parent_dir}/#{repo_name}-bare master:master --tags --force; " : ''}
          git push -q #{ssh_user}@#{hostname}:#{remote_repo_parent_dir}/#{repo_name}-bare #{branch}:master --tags --force

          #######
          # End shell code
          SHELL

        puts "Done"
      ensure
        reset_temp_commit
      end
    end

    def sync_sibling_repo(repo_name, repo_dir, hostname, remote_repo_parent_dir="/root", ssh_user="root")
      exists = File.exists?(repo_dir)
      inside(repo_dir) do
        sync_repo(repo_name, hostname, remote_repo_parent_dir, ssh_user)
      end if exists
      exists
    end
    
    def update_test_bundle(hostname, user, *dirs)
      cmd = ""
      dirs.each do |dir|
        cmd += "cd ~/openshift-test/#{dir}; rm Gemfile.lock; bundle install --local; touch Gemfile.lock;\n"
      end
      ssh(hostname, cmd, 60, false, 1, user)
    end

    # clones origin-server/rhc over to remote;
    # returns command to run remotely for cloning to standard working dirs,
    # plus the names of those working dirs
    def sync_available_sibling_repos(hostname, remote_repo_parent_dir="/root", ssh_user="root")
      working_dirs = ''
      clone_commands = ''
      SIBLING_REPOS.each do |repo_name, repo_dirs|
        repo_dirs.each do |repo_dir|

          if sync_sibling_repo(repo_name, repo_dir, hostname, remote_repo_parent_dir, ssh_user)
            working_dirs += "#{repo_name} "
            clone_commands += "git clone #{repo_name}-bare #{repo_name}; "
            break # just need the first repo found
          end
        end
      end
      return clone_commands, working_dirs
    end
    
    def repo_clone_commands(hostname)
      clone_commands = ''
      SIBLING_REPOS.each_key do |repo_name|
        clone_commands += "git clone #{repo_name}-bare #{repo_name}; "
      end
      clone_commands
    end

    def init_repos(hostname, replace=true, repo=nil, remote_repo_parent_dir="/root", ssh_user="root")
      git_clone_commands = ''

      SIBLING_REPOS.each do |repo_name, repo_dirs|
        if repo.nil? or repo == repo_name
          repo_git_url = SIBLING_REPOS_GIT_URL[repo_name]
          git_clone_commands += "if [ ! -d #{remote_repo_parent_dir}/#{repo_name}-bare ]; then\n" unless replace
          git_clone_commands += "rm -rf #{remote_repo_parent_dir}/#{repo_name}; git clone --bare #{repo_git_url} #{remote_repo_parent_dir}/#{repo_name}-bare;\n"
          git_clone_commands += "fi\n" unless replace
        end
      end
      ssh(hostname, git_clone_commands, 240, false, 10, ssh_user)
    end

    def get_required_packages
      required_packages_str = ""
      packages = get_sorted_package_names
      ignore_packages = get_ignore_packages

      SIBLING_REPOS.each do |repo_name, repo_dirs|
        repo_dirs.each do |repo_dir|
          exists = File.exists?(repo_dir)
          inside(repo_dir) do
            spec_file_list = `find -name *.spec`.split("\n")
            spec_file_list.each do |spec_file|
              package = Package.new(spec_file, File.dirname(spec_file))
              package_name = package.name
              unless ignore_packages.include?(package.name)
                required_packages = package.build_requires + package.requires
                required_packages.each do |r_package|
                  required_packages_str += " \\\"#{r_package.yum_name_with_version}\\\"" unless packages.include?(r_package.name)
                end
              end
            end
          end if exists
        end
      end
      required_packages_str
    end

    def get_sorted_package_names
      packages = get_packages(true)
      packages_str = ""
      packages.keys.sort.each do |package_name|
        packages_str += " #{package_name}"
      end
      packages_str
    end

    def get_ignore_packages(include_unmodified=false)
      packages_str = ""
      IGNORE_PACKAGES.each do |package_name|
        packages_str += " #{package_name}"
      end

      if options.include_unmodified?
        build_dirs = get_build_dirs

        all_packages = get_packages
        build_dirs.each do |build_info|
          package_name = build_info[0]
          all_packages.delete(package_name)
        end

        all_packages.keys.each do |package_name|
          packages_str += " #{package_name}"
        end
      end

      packages_str
    end

    def temp_commit
      # Warn on uncommitted changes
      `git diff-index --quiet HEAD`

      if $? != 0
        # Perform a temporary commit
        puts "Creating temporary commit to build"
        `git commit -a -m "Temporary commit to build"`
        if $? != 0
          puts "No-op."
        else
          @temp_commit = true
          puts "Done."
        end
      end
    end

    def reset_temp_commit
      if @temp_commit
        puts "Undoing temporary commit..."
        `git reset HEAD^`
        @temp_commit = false
        puts "Done."
      end
    end

    def mcollective_logs(hostname)
      puts "Keep all mcollective logs on remote instance: #{hostname}"
      ssh(hostname, "echo keeplogs=9999 >> /etc/mcollective/server.cfg", 240)
      ssh(hostname, "/sbin/service mcollective restart", 240)
    end

    def update_api_file(instance)
      public_ip = instance.dns_name
      external_config = "~/.openshift/console.conf"
      config_file = File.expand_path(external_config)

      Dir.mkdir(File.expand_path('~/.openshift')) rescue nil

      if not FileTest.exists?(config_file)
        puts "File '#{external_config}' does not exist, creating..."
        system("touch #{external_config}")
        File.open(config_file, 'w') do |f| f.write(<<-END
BROKER_URL=https://#{public_ip}/broker/rest
DOMAIN_SUFFIX=dev.rhcloud.com
COMMUNITY_URL=https://#{public_ip}:8118/
# Uncomment the next line to set a proxy URL for the broker
# BROKER_PROXY_URL=
          END
          )
        end

      else
        puts "Updating ~/.openshift/console.conf with public ip = #{public_ip}"
        s = IO.read(config_file)
        s.gsub!(%r[^BROKER_URL=\s*https://[^/]+/broker/rest$]m, "BROKER_URL=https://#{public_ip}/broker/rest")
        s.gsub!(%r[^COMMUNITY_URL=\s*https://.+$]m, "COMMUNITY_URL=https://#{public_ip}:8118/")
        File.open(config_file, 'w'){ |f| f.write(s) }
      end
    end

    def update_ssh_config_verifier(instance)
      public_ip = instance.public_ip_address
      ssh_config = "~/.ssh/config"
      pem_file = File.expand_path("~/.ssh/libra.pem")
      if not File.exist?(pem_file)
        # copy it from local repo
        cmd = "cp misc/libra.pem #{pem_file}"
        puts cmd
        system(cmd)
        system("chmod 600 #{pem_file}")
      end
      config_file = File.expand_path(ssh_config)

      config_template = <<END
Host verifier
  HostName 10.1.1.1
  User      root
  IdentityFile ~/.ssh/libra.pem
END

      if not FileTest.exists?(config_file)
        puts "File '#{ssh_config}' does not exists, creating..."
        system("touch #{ssh_config}")
        cmd = "chmod 600 #{ssh_config}"
        system(cmd)
        file_mode = 'w'
        File.open(config_file, file_mode) { |f| f.write(config_template) }
      else
        if not system("grep -n 'Host verifier' #{config_file}")
          file_mode = 'a'
          File.open(config_file, file_mode) { |f| f.write(config_template) }
        end

      end

      line_num = `grep -n 'Host verifier' ~/.ssh/config`.chomp.split(':')[0]
      puts "Updating ~/.ssh/config verifier entry with public ip = #{public_ip}"
      (1..4).each do |i|
        `sed -i -e '#{line_num.to_i + i}s,HostName.*,HostName #{public_ip},' ~/.ssh/config`
      end
    end

    def update_express_server(instance)
      public_ip = instance.public_ip_address
      puts "Updating ~/.openshift/express.conf libra_server entry with public ip = #{public_ip}"
      `sed -i -e 's,^libra_server.*,libra_server=#{public_ip},' ~/.openshift/express.conf`
    end

    def repo_path(dir='')
      File.expand_path("../#{dir}", File.dirname(__FILE__))
    end

    def run_ssh(hostname, title, cmd, timeout=@@SSH_TIMEOUT, ssh_user="root")
      output, code = ssh(hostname, cmd, timeout, true, 1, ssh_user)
      puts <<-eos


          -----------------------------------------------------------
                      Begin Output From #{title} Tests
          -----------------------------------------------------------

# #{cmd}

#{output}

          -----------------------------------------------------------
                       End Output From #{title} Tests
          -----------------------------------------------------------


      eos
      return output, code
    end

    def reboot(instance)
      print "Rebooting instance to apply new kernel..."
      instance.reboot
      puts "Done"
    end

    def add_ssh_cmd_to_threads(hostname, threads, failures, titles, cmds, retry_individually=false, timeouts=@@SSH_TIMEOUT, ssh_user="root")
      titles = [titles] unless titles.kind_of?(Array)
      cmds = [cmds] unless cmds.kind_of?(Array)
      retry_individually = [retry_individually] unless retry_individually.kind_of? Array
      timeouts = [timeouts] unless timeouts.kind_of? Array
      start_time = Time.new
      threads << [ Thread.new {
        multi = cmds.length > 1
        cmds.each_with_index do |cmd, index|
          title = titles[index]
          retry_individ = retry_individually[index]
          timeout = timeouts[index]
          output, exit_code = run_ssh(hostname, title, cmd, timeout, ssh_user)
          if exit_code != 0
            if output.include?("Failing Scenarios:") && output =~ /cucumber openshift-test\/tests\/.*\.feature:\d+/
              output.lines.each do |line|
                if line =~ /cucumber openshift-test\/tests\/(.*\.feature):(\d+)/
                  test = $1
                  scenario = $2
                  if retry_individ
                    failures.push(["#{title} (#{test}:#{scenario})", "su -c \"cucumber #{CUCUMBER_OPTIONS} openshift-test/tests/#{test}:#{scenario}\""])
                  else
                    failures.push(["#{title} (#{test})", "su -c \"cucumber #{CUCUMBER_OPTIONS} openshift-test/tests/#{test}\""])
                  end
                end
              end
            elsif retry_individ && output.include?("Failure:") && output.include?("rake_test_loader")
              found_test = false
              output.lines.each do |line|
                if line =~ /\A(test_\w+)\((\w+Test)\) \[\/.*\/(test\/.*_test\.rb):(\d+)\]:/
                  found_test = true
                  test_name = $1
                  class_name = $2
                  file_name = $3

                  # determine if the first part of the command is a directory change
                  # if so, include that in the retry command
                  chdir_command = ""
                  if cmd =~ /\A(cd .+?; )/
                    chdir_command = $1
                  end
                  failures.push(["#{class_name} (#{test_name})", "#{chdir_command} ruby -Ilib:test #{file_name} -n #{test_name}"])
                end
              end
              failures.push([title, cmd]) unless found_test
            else
              failures.push([title, cmd])
            end
          end

          still_running_tests = ''
          threads.each do |t|
            t[1].delete(title)
            still_running_tests += "   #{t[1].pretty_inspect}" unless t[1].empty?
          end
          if still_running_tests.length > 0
            mins, secs = (Time.new - start_time).abs.divmod(60)
            puts "Still Running Tests (#{mins}m #{secs.to_i}s):"
            puts still_running_tests
          end
        end
      }, Array.new(titles) ]
    end

    def reset_test_dir(hostname, backup=false, ssh_user="root")
      ssh(hostname, %{
cat<<EOF > /tmp/reset_test_dir.sh
if [ -d /tmp/rhc ]
then
    if #{backup}
    then
        if \\\$(ls /tmp/rhc/run_* > /dev/null 2>&1)
        then
            rm -rf /tmp/rhc_previous_runs
            mkdir -p /tmp/rhc_previous_runs
            mv /tmp/rhc/run_* /tmp/rhc_previous_runs
        fi
        if \\\$(ls /tmp/rhc/* > /dev/null 2>&1)
        then
            for i in {1..100}
            do
                if ! [ -d /tmp/rhc_previous_runs/run_$i ]
                then
                    mkdir -p /tmp/rhc_previous_runs/run_$i
                    mv /tmp/rhc/* /tmp/rhc_previous_runs/run_$i
                    break
                fi
            done
        fi
        if \\\$(ls /tmp/rhc_previous_runs/run_* > /dev/null 2>&1)
        then
            mv /tmp/rhc_previous_runs/run_* /tmp/rhc/
            rm -rf /tmp/rhc_previous_runs
        fi
    else
        rm -rf /tmp/rhc
    fi
fi
mkdir -p /tmp/rhc/junit
EOF
chmod +x /tmp/reset_test_dir.sh
}, 120, true, 1, ssh_user)
      ssh(hostname, "su -c '/tmp/reset_test_dir.sh'" , 120, true, 1, ssh_user)
    end

    def retry_test_failures(hostname, failures, num_retries=1, timeout=@@SSH_TIMEOUT, ssh_user="root")
      failures.reverse!
      puts "All Failures: #{failures.pretty_inspect}"
      reset_test_dir(hostname, true, ssh_user)
      failures.each do |failure|
        title = failure[0]
        cmd = failure[1]
        (1..num_retries).each do |i|
          puts "Retry attempt #{i} for: #{title}"
          output, exit_code = run_ssh(hostname, title, cmd, timeout, ssh_user)
          if exit_code != 0
            if i == num_retries
              exit exit_code
            else
              reset_test_dir(hostname, true, ssh_user)
            end
          else
            break
          end
        end
      end
    end
    
    def devenv_branch_wildcard(branch)
      wildcard = nil
      if branch == 'master'
        wildcard = "#{DEVENV_NAME}_*"
      else
        wildcard = "#{DEVENV_NAME}-#{branch}_*"
      end
      wildcard
    end
    
    def devenv_base_branch_wildcard(branch)
      wildcard = nil
      if branch == 'master'
        wildcard = "#{DEVENV_NAME}-base_*"
      else
        wildcard = "#{DEVENV_NAME}-#{branch}-base_*"
      end
      wildcard
    end
    
    def print_highlighted_output(title, out)
      puts
      puts "------------------ Begin #{title} ------------------------"
      puts out
      puts "------------------- End #{title} -------------------------"
      puts
    end
    
    def print_and_exit(ret, out)
      if ret != 0
        puts "Exiting with error code #{ret}"
        puts "Output: #{out}"
        exit ret
      end
    end

  end
end
