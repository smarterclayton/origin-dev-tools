#
# Global definitions
#

# Fedora 17 image
AMI = {"us-east-1" =>"ami-6145cc08"}

TYPE = "m1.large"
KEY_PAIR = "libra"
ZONE = 'us-east-1d'

DEVENV_NAME = 'oso-fedora'

VERIFIER_REGEXS = {}
TERMINATE_REGEX = /terminate/
VERIFIED_TAG = "qe-ready"

# Specify the source location of the SSH key
# This will be used if the key is not found at the location specified by "RSA"
RSA = File.expand_path("~/.ssh/devenv.pem")
RSA_SOURCE = ""

SAUCE_USER = ""
SAUCE_SECRET = ""
SAUCE_OS = ""
SAUCE_BROWSER = ""
SAUCE_BROWSER_VERSION = ""
CAN_SSH_TIMEOUT=90
SLEEP_AFTER_LAUNCH=60

SIBLING_REPOS = {
                  'origin-server' => ['../origin-server'],
                  'rhc' => ['../rhc'],
                  'origin-dev-tools' => ['../origin-dev-tools'],
                  'origin-community-cartridges' => ['../origin-community-cartridges'],                  
                  'puppet-openshift_origin' => ['../puppet-openshift_origin'],
               }
OPENSHIFT_ARCHIVE_DIR_MAP = {'rhc' => 'rhc/'}
SIBLING_REPOS_GIT_URL = {
                        'origin-server' => 'https://github.com/openshift/origin-server.git',
                        'rhc' => 'https://github.com/openshift/rhc.git',
                        'origin-dev-tools' => 'https://github.com/openshift/origin-dev-tools.git',
                        'origin-community-cartridges' => 'https://github.com/openshift/origin-community-cartridges.git',
                        'puppet-openshift_origin' => 'https://github.com/kraman/puppet-openshift_origin.git'
                      }

DEV_TOOLS_REPO = 'origin-dev-tools'
DEV_TOOLS_EXT_REPO = DEV_TOOLS_REPO
ADDTL_SIBLING_REPOS = SIBLING_REPOS_GIT_URL.keys - [DEV_TOOLS_REPO]

DISTRO_NAME = `lsb_release -i`.gsub(/Distributor ID:\s*/,'').strip
DISTRO_VERSION = `lsb_release -r`.gsub(/Release:\s*/,'').strip

ignore_packages = ['rubygem-openshift-origin-auth-kerberos', 'openshift-origin-cartridge-jbossews-1.0', 'openshift-origin-cartridge-jbossews-2.0']
if DISTRO_NAME == 'Fedora' 
  #RHEL 6.3 cartridges
  ignore_packages << 'openshift-origin-cartridge-postgresql-8.4' 
  ignore_packages << "openshift-origin-cartridge-ruby-1.8"
  ignore_packages << "openshift-origin-cartridge-ruby-1.9-scl"
  ignore_packages << 'openshift-origin-util-scl' 
  ignore_packages << 'openshift-origin-cartridge-jbossas-7'
  ignore_packages << 'openshift-origin-cartridge-switchyard-0.6'
  ignore_packages << 'openshift-origin-cartridge-perl-5.10'
  ignore_packages << 'openshift-origin-cartridge-php-5.3'
  ignore_packages << 'openshift-origin-cartridge-python-2.6'
  ignore_packages << 'openshift-origin-cartridge-phpmyadmin-3.4'
  
  CUCUMBER_OPTIONS = '--strict -f progress -f junit --out /tmp/rhc/cucumber_results -t ~@rhel-only'
  BROKER_CUCUMBER_OPTIONS = '--strict -f html --out /tmp/rhc/broker_cucumber.html -f progress  -t ~@rhel-only'
else
  CUCUMBER_OPTIONS = '--strict -f progress -f junit --out /tmp/rhc/cucumber_results -t ~@fedora-only'
  BROKER_CUCUMBER_OPTIONS = '--strict -f html --out /tmp/rhc/broker_cucumber.html -f progress  -t ~@fedora-only'
end

ignore_packages << "openshift-origin-cartridge-jbosseap-6.0" if `yum search jboss-eap6 2> /dev/null`.match(/No Matches found/)
ignore_packages << "openshift-origin-cartridge-jbossas-7" if `yum search jboss-as7 2> /dev/null`.match(/No Matches found/)
ignore_packages << "openshift-origin-cartridge-switchyard-0.6" if `yum search jboss-as7 2> /dev/null`.match(/No Matches found/)

IGNORE_PACKAGES = ignore_packages
$amz_options = {:key_name => KEY_PAIR, :instance_type => TYPE}
  
ACCEPT_DEVENV_SCRIPT = 'true'
