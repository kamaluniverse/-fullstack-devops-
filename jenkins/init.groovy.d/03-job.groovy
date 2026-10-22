// Creates the declarative pipeline job, checked out from the local mirror.
// For GitHub, replace the URL with your repository and set the branch.
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import hudson.plugins.git.GitSCM
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.UserRemoteConfig

def instance = Jenkins.getInstance()
def jobName = 'proshop-pipeline'
def repoUrl = new File('/etc/jenkins-repo-url').exists()
    ? new File('/etc/jenkins-repo-url').text.trim()
    : 'file:///opt/proshop-repo.git'

if (instance.getItem(jobName) == null) {
    def scm = new GitSCM(
        [new UserRemoteConfig(repoUrl, 'origin', null, null)],
        [new BranchSpec('*/main')],
        false, [], null, null, []
    )
    def job = instance.createProject(WorkflowJob, jobName)
    job.definition = new CpsScmFlowDefinition(scm, 'Jenkinsfile')
    job.save()
    println "[init] pipeline job ${jobName} created from ${repoUrl}"
}
