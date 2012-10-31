#
# Global definitions
#

# Fedora 16 image
AMI = {"us-east-1" =>"ami-0316d86a"}

# Fedora 17 image
#AMI = {"us-east-1" =>"ami-2ea50247"}

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

SIBLING_REPOS = {'origin-server' => ['../origin-server'],
                 'rhc' => ['../rhc'],
                 'origin-dev-tools' => ['../origin-dev-tools']}
SIBLING_REPOS_GIT_URL = {'origin-server' => 'https://github.com/openshift/origin-server.git',
                        'rhc' => 'https://github.com/openshift/rhc.git',
                        'origin-dev-tools' => 'https://github.com/openshift/origin-dev-tools.git'}

DEV_TOOLS_REPO = 'origin-dev-tools'
DEV_TOOLS_EXT_REPO = DEV_TOOLS_REPO
ADDTL_SIBLING_REPOS = SIBLING_REPOS_GIT_URL.keys - [DEV_TOOLS_REPO]

CUCUMBER_OPTIONS = '--strict -f progress -f junit --out /tmp/rhc/cucumber_results -t ~@not-origin'

redhat_release = File.open("/etc/redhat-release").read
ignore_packages = ['rubygem-openshift-origin-auth-kerberos', 'rubygem-openshift-origin-console', 'openshift-console', 'openshift-origin-cartridge-jbossews-1.0', 'openshift-origin-cartridge-jbossews-2.0']
ignore_packages << "openshift-origin-cartridge-ruby-1.9-scl" if redhat_release.match(/Fedora/)
ignore_packages << "openshift-origin-cartridge-jbosseap-6.0" if `rpm -q jboss-eap6 2> /dev/null`.match(/is not installed/)
ignore_packages << "openshift-origin-cartridge-jbossas-7" if `rpm -q jboss-as7 2> /dev/null`.match(/is not installed/)
ignore_packages << "openshift-origin-cartridge-jenkins-1.4" if `rpm -q jenkins-plugin-openshift 2> /dev/null`.match(/is not installed/)
ignore_packages << "openshift-origin-cartridge-nodejs-0.6" if `rpm -q nodejs-supervisor 2> /dev/null`.match(/is not installed/)

IGNORE_PACKAGES = ignore_packages
$amz_options = {:key_name => KEY_PAIR, :instance_type => TYPE}
