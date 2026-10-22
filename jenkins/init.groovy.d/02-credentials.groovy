// Registers the credentials used by the pipeline:
//   app-ssh-key   : SSH private key for the application EC2 host
//   ecr-registry  : ECR registry hostname (kept out of the Jenkinsfile)
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.plugins.credentials.impl.StringCredentialsImpl
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
import hudson.util.Secret

def store = SystemCredentialsProvider.getInstance().getStore()
def domain = Domain.global()
def existing = store.getCredentials(domain).collect { it.id }

def keyPath = '/var/lib/jenkins/.ssh/proshop-key'
if (new File(keyPath).exists() && !existing.contains('app-ssh-key')) {
    def source = new BasicSSHUserPrivateKey.FileOnMasterPrivateKeySource(keyPath)
    store.addCredentials(domain, new BasicSSHUserPrivateKey(
        CredentialsScope.GLOBAL,
        'app-ssh-key',
        'ubuntu',
        source,
        '',
        'SSH key for the ProShop app EC2 host'
    ))
    println '[init] app-ssh-key credential created'
}

def ecrFile = new File('/etc/jenkins-ecr-registry')
if (ecrFile.exists() && !existing.contains('ecr-registry')) {
    store.addCredentials(domain, new StringCredentialsImpl(
        CredentialsScope.GLOBAL,
        'ecr-registry',
        'Amazon ECR registry hostname',
        Secret.fromString(ecrFile.text.trim())
    ))
    println '[init] ecr-registry credential created'
}
