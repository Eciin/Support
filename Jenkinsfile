pipeline {
    agent any
    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        
        stage('Build') {
            steps {
                echo 'Building application...'
                sh 'terraform init'
                sh 'chmod -R +x .terraform/providers'
                sh 'terraform validate'
            }
        }
        
        stage('Deploy to Staging') {
            steps {
                echo 'Deploying to staging environment...'
                sh 'terraform plan -out=tfplan'
                sh 'terraform apply -auto-approve tfplan'
            }
        }
        
        stage('Test on Staging') {
            steps {
                echo 'Running tests on staging environment...'
                // Wait for services to start
                sh 'sleep 30'
                // Get the load balancer IP from Terraform output
                script {
                    def loadBalancerIp = sh(script: 'terraform output -raw load_balancer_ip', returnStdout: true).trim()
                    
                    echo 'Running stress test on load balancer...'
                    sh "sshpass -p 'student' ssh -o StrictHostKeyChecking=no student@${loadBalancerIp} 'stress --cpu 2 --timeout 200'"
                    
                    echo 'Waiting for auto-scaling to respond to the load...'
                    sh 'sleep 90'
                }
            }
        }
        
        stage('Destroy Staging') {
            steps {
                echo 'Destroying staging environment...'
                sh 'terraform destroy -auto-approve'
            }
        }
        
        stage('Approval for Production') {
            steps
            timeout(time: 30, unit: 'SECONDS') {
                input message: 'Tests on staging passed. Deploy to production?', ok: 'Approve'
            }
        }
        
        stage('Deploy to Production') {
            steps {
                echo 'Deploying to production environment...'
                sh 'terraform plan -out=tfplan_prod'
                sh 'terraform apply -auto-approve tfplan_prod'
            }
        }
    }
    
    post {
        success {
            echo 'Pipeline completed successfully!'
        }
        failure {
            echo 'Pipeline failed!'
            // Clean up staging environment if it exists and the pipeline failed
            script {
                try {
                    sh 'terraform destroy -auto-approve || true'
                } catch (Exception e) {
                    echo 'Failed to destroy staging environment: ' + e.getMessage()
                }
            }
        }
    }
}