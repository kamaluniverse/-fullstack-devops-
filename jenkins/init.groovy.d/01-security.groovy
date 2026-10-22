// Creates the admin account and disables anonymous access.
// The password is read from /etc/jenkins-admin-pass (root-owned, 0600).
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import jenkins.install.InstallState

def instance = Jenkins.getInstance()
def passFile = new File('/etc/jenkins-admin-pass')

if (passFile.exists()) {
    def password = passFile.text.trim()
    def realm = new HudsonPrivateSecurityRealm(false)

    try {
        realm.createAccount('admin', password)
    } catch (Exception ignored) {
        // Account already exists: force it back to the password in the file so
        // re-running the bootstrap is deterministic.
        def admin = realm.getAllUsers().find { it.id == 'admin' }
        admin?.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(password))
    }

    instance.setSecurityRealm(realm)

    def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
    strategy.setAllowAnonymousRead(false)
    instance.setAuthorizationStrategy(strategy)
    instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
    instance.save()

    println '[init] admin security realm configured'
}
