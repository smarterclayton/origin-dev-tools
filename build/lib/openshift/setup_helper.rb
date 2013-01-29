module SetupHelper
  BUILD_REQUIREMENTS = ["tito","yum-plugin-priorities","git","make","wget","redhat-lsb","vim-enhanced"]
  BUILD_GEM_REQUIREMENTS = {"aws-sdk"=>"","rake"=>"","thor"=>"","parseconfig"=>"","yard"=>"","redcarpet"=>""}

  # Ensure that openshift mirror repository and all build requirements are installed.
  # On RHEL6, it also verifies that the build script is running within SCL-Ruby 1.9.3.
  def self.ensure_build_requirements
    raise "Unsupported Operating system. Currently the OpenShift Origin build scripts only work with Fedora 17 and RHEL 6 releases." unless File.exist?("/etc/redhat-release")
    packages = BUILD_REQUIREMENTS.select{ |rpm| `rpm -q #{rpm}`.match(/is not installed/) }
    if packages.length > 0
      puts "You are the following packages which are required to run this build script. Installing..."
      puts packages.map{|p| "\t#{p}"}.join("\n")
      system "yum install -y #{packages.join(" ")}"
    end
    
    scl_prefix = `lsb_release -i`.gsub(/Distributor ID:\s*/,'').strip == "RedHatEnterpriseServer" ? "ruby193-" : ""
    BUILD_GEM_REQUIREMENTS.each do |gem_name, version|
      if version.nil? or version.empty?
        `gem list -i #{gem_name}`
        is_installed = ($? == 0)
        puts "Installing gem #{gem_name}" unless is_installed
        system "yum install -y '#{scl_prefix}rubygem-#{gem_name}'" unless is_installed
      else
        `gem list -i #{gem_name} -v #{version}`
        is_installed = ($? == 0)
        next if is_installed
        puts "Installing gem #{gem_name}"
        success = run "yum install -y '#{scl_prefix}rubygem-#{gem_name} = #{version}'"
        system "gem install #{gem_name} -v #{version}" unless success
      end
    end

    create_openshift_deps_rpm_repository
    if RUBY_VERSION != "1.9.3"
      if `lsb_release -i`.gsub(/Distributor ID:\s*/,'').strip == "RedHatEnterpriseServer"
        puts "Unsupported ruby version #{RUBY_VERSION}. Please ensure that you are running within a ruby193 scl container:\n"
        puts "\tyum install scl-utils ruby193\n\tscl enable ruby193 /bin/bash\n"
        exit
      else
        puts "Unsupported ruby version #{RUBY_VERSION}. Please ensure that you are running Ruby 1.9.3\n"
        exit
      end
    end
  end

  # Create a RPM repository for OpenShift Origin dependencies available on the mirror.openshift.com site
  def self.create_openshift_deps_rpm_repository
    if `lsb_release -i`.gsub(/Distributor ID:\s*/,'').strip == "RedHatEnterpriseServer"
      url = "https://mirror.openshift.com/pub/openshift-origin/rhel-6/$basearch/"
    else
      url = "https://mirror.openshift.com/pub/openshift-origin/fedora-17/$basearch/"
    end

    unless File.exist?("/etc/yum.repos.d/openshift-origin-deps.repo")
      File.open("/etc/yum.repos.d/openshift-origin-deps.repo","w") do |file|
        file.write %{
[openshift-origin-deps]
name=openshift-origin-deps
baseurl=#{url}
gpgcheck=0
enabled=1
        }
      end
      
      File.open("/etc/yum.repos.d/puppetlabs-products.repo","w") do |file|
        file.write %{
[puppetlabs-products]
name=Puppet Labs Products Fedora 17 - $basearch
baseurl=http://yum.puppetlabs.com/fedora/f17/products/$basearch
gpgkey=http://yum.puppetlabs.com/RPM-GPG-KEY-puppetlabs
enabled=0
gpgcheck=1
        }
      end
    end
  end
end