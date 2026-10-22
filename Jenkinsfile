pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '5'))
        disableConcurrentBuilds()
    }

    environment {
        AWS_REGION      = 'us-east-1'
        ECR_REPO_PREFIX = 'proshop'
        APP_USER        = 'ubuntu'
        APP_DIR         = '/opt/proshop'
        // Deployment target as seen from the Jenkins host. This is the app
        // server's private IP inside the VPC (the public Elastic IP is for end
        // users and does not hairpin reliably from inside the VPC). Override
        // per-environment with APP_HOST_OVERRIDE; never commit secrets here.
        APP_HOST        = '10.0.1.84'
    }

    parameters {
        string(name: 'APP_HOST_OVERRIDE', defaultValue: '', description: 'Application EC2 public IP or DNS name')
        string(name: 'DEPLOY_TAG', defaultValue: '', description: 'Image tag to deploy (defaults to the short git SHA)')
        booleanParam(name: 'SKIP_DEPLOY', defaultValue: false, description: 'Build and push images without deploying')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_SHA = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    env.IMAGE_TAG = params.DEPLOY_TAG?.trim() ? params.DEPLOY_TAG.trim() : env.GIT_SHA
                }
            }
        }

        stage('Install dependencies') {
            parallel {
                stage('backend') {
                    steps { dir('backend') { sh 'npm ci --no-audit --no-fund' } }
                }
                stage('frontend') {
                    steps { dir('frontend') { sh 'npm ci --no-audit --no-fund' } }
                }
            }
        }

        stage('Test') {
            parallel {
                stage('backend tests') {
                    steps { dir('backend') { sh 'npm test' } }
                }
                stage('frontend tests') {
                    steps { dir('frontend') { sh 'npm test' } }
                }
            }
        }

        stage('Lint') {
            parallel {
                stage('backend lint') {
                    steps { dir('backend') { sh 'npm run lint' } }
                }
                stage('frontend lint') {
                    steps { dir('frontend') { sh 'npm run lint' } }
                }
            }
        }

        stage('Build images') {
            steps {
                withCredentials([string(credentialsId: 'ecr-registry', variable: 'ECR_REGISTRY')]) {
                    sh '''
                        docker build -t "$ECR_REGISTRY/$ECR_REPO_PREFIX/backend:$IMAGE_TAG" ./backend
                        docker build -t "$ECR_REGISTRY/$ECR_REPO_PREFIX/frontend:$IMAGE_TAG" ./frontend
                    '''
                }
            }
        }

        stage('Push to ECR') {
            steps {
                withCredentials([string(credentialsId: 'ecr-registry', variable: 'ECR_REGISTRY')]) {
                    sh '''
                        aws ecr get-login-password --region "$AWS_REGION" \
                          | docker login --username AWS --password-stdin "$ECR_REGISTRY"
                        docker push "$ECR_REGISTRY/$ECR_REPO_PREFIX/backend:$IMAGE_TAG"
                        docker push "$ECR_REGISTRY/$ECR_REPO_PREFIX/frontend:$IMAGE_TAG"
                    '''
                }
            }
        }

        stage('Deploy to EC2') {
            when { expression { !params.SKIP_DEPLOY } }
            steps {
                sshagent(credentials: ['app-ssh-key']) {
                    sh '''
                        HOST="${APP_HOST_OVERRIDE:-$APP_HOST}"
                        test "$HOST" != "REPLACE_WITH_APP_PUBLIC_IP" || {
                          echo "Set APP_HOST_OVERRIDE (or edit APP_HOST) before deploying" >&2
                          exit 1
                        }

                        # Pin the host key on first use; never disable verification.
                        mkdir -p ~/.ssh && chmod 700 ~/.ssh
                        ssh-keyscan -H "$HOST" >> ~/.ssh/known_hosts 2>/dev/null

                        scp -o StrictHostKeyChecking=yes compose.yaml "$APP_USER@$HOST:$APP_DIR/"
                        scp -o StrictHostKeyChecking=yes nginx/default.conf "$APP_USER@$HOST:$APP_DIR/nginx/"
                        scp -o StrictHostKeyChecking=yes scripts/deploy.sh scripts/health-check.sh "$APP_USER@$HOST:$APP_DIR/scripts/"

                        ssh -o StrictHostKeyChecking=yes "$APP_USER@$HOST" \
                          "chmod +x $APP_DIR/scripts/*.sh && cd $APP_DIR && TAG=$IMAGE_TAG ./scripts/deploy.sh"
                    '''
                }
            }
        }

        stage('Health check') {
            when { expression { !params.SKIP_DEPLOY } }
            steps {
                sh '''
                    HOST="${APP_HOST_OVERRIDE:-$APP_HOST}"
                    curl -fsS --retry 12 --retry-delay 5 --max-time 15 "http://$HOST/api/health"
                '''
            }
        }
    }

    post {
        success {
            echo "Deployed ${env.IMAGE_TAG} successfully. Rollback: ssh to the app host and run ./scripts/deploy.sh rollback"
        }
        failure {
            echo 'Pipeline failed. Images tagged with this SHA may already be in ECR; the app host keeps its previous healthy deployment until deploy.sh succeeds.'
        }
        always {
            sh 'docker image prune -f --filter "until=24h" || true'
        }
    }
}
