// Lab 2: jenkins-flask-api-pipeline
// GitHub push -> Jenkins -> lint + unit tests (disposable Python container)
// -> package -> release on the app server (own virtualenv) -> restart service
// -> health check through nginx -> automatic rollback if unhealthy.
//
// One-time Jenkins setup (see README):
//   - Credential 'app-server-deploy' (SSH username with private key, user 'deploy')  [Lab 1]
//   - Global environment variable APP_HOST = private IP of the app server              [Lab 1]
//   - App server host key in the Jenkins user's ~/.ssh/known_hosts                      [Lab 1]

pipeline {
  agent any

  options {
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 15, unit: 'MINUTES')
  }

  triggers {
    githubPush()
  }

  parameters {
    choice(name: 'ACTION', choices: ['deploy', 'rollback'],
           description: 'deploy = test and release this commit; rollback = switch back to the previous healthy release')
  }

  environment {
    APP_ROOT      = '/opt/flask-api'
    HEALTH_URL    = 'http://127.0.0.1:8084/health'   // through nginx, as users reach it
    KEEP_RELEASES = '5'
    TEST_IMAGE    = 'python:3.11-slim'
    SSH_OPTS      = '-o BatchMode=yes -o ConnectTimeout=10'
  }

  stages {
    stage('Preflight') {
      steps {
        script {
          if (!env.APP_HOST?.trim()) {
            error('APP_HOST is not set: Manage Jenkins > System > Global properties > Environment variables')
          }
          env.RELEASE = sh(
            script: 'printf "%05d-%s" "$BUILD_NUMBER" "$(echo "${GIT_COMMIT:-manual}" | cut -c1-7)"',
            returnStdout: true
          ).trim()
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.ACTION}"
          currentBuild.description = (params.ACTION == 'deploy') ? "release ${env.RELEASE}" : 'rollback'
        }
        sh '''
          if [ "${ACTION:-deploy}" = "deploy" ]; then
            docker info >/dev/null 2>&1 || { echo "Jenkins cannot use Docker (needed for the test stage)"; exit 1; }
          fi
        '''
        sshagent(credentials: ['app-server-deploy']) {
          sh '''ssh $SSH_OPTS deploy@$APP_HOST 'echo "connected to $(hostname -s) as $(whoami)"' '''
        }
      }
    }

    stage('Lint & test') {
      when { expression { params.ACTION == 'deploy' } }
      steps {
        sh '''
          if grep -rIlE --exclude-dir=.git -e "-----BEGIN [A-Z ]*PRIVATE KEY-----" . ; then
            echo "Refusing to build: a private key is committed in the file(s) above"
            exit 1
          fi

          rm -rf reports && mkdir -p reports

          # Run in a throwaway container that shares this Jenkins container's volumes,
          # so the workspace is at the same path. Runs as the Jenkins user, so no
          # root-owned files are left behind in the workspace.
          JC=$(hostname)
          docker inspect "$JC" >/dev/null 2>&1 || JC=jenkins

          docker run --rm --volumes-from "$JC" -w "$WORKSPACE" \
            -u "$(id -u):$(id -g)" -e HOME=/tmp \
            -e PIP_DISABLE_PIP_VERSION_CHECK=1 -e PYTHONDONTWRITEBYTECODE=1 \
            "$TEST_IMAGE" sh -ec '
              python -m venv /tmp/venv
              /tmp/venv/bin/pip install -q -r requirements-dev.txt
              echo "--- flake8"
              /tmp/venv/bin/flake8 --tee --output-file reports/flake8.txt
              echo "flake8: clean"
              echo "--- pytest"
              /tmp/venv/bin/pytest -p no:cacheprovider --junitxml=reports/junit.xml
            '
        '''
      }
    }

    stage('Package') {
      when { expression { params.ACTION == 'deploy' } }
      steps {
        sh '''
          rm -rf build release.tgz
          mkdir -p build
          cp -a app.py requirements.txt data build/
          {
            echo "release=$RELEASE"
            echo "commit=${GIT_COMMIT:-unknown}"
            echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          } > build/RELEASE
          tar -C build -czf release.tgz .
          tar -tzf release.tgz
        '''
      }
    }

    stage('Deploy') {
      when { expression { params.ACTION == 'deploy' } }
      steps {
        sshagent(credentials: ['app-server-deploy']) {
          sh '''
            ssh $SSH_OPTS deploy@$APP_HOST "mkdir -p $APP_ROOT/releases/$RELEASE && tar -xzf - -C $APP_ROOT/releases/$RELEASE" < release.tgz
            ssh $SSH_OPTS deploy@$APP_HOST bash -s -- deploy "$APP_ROOT" "$RELEASE" "$KEEP_RELEASES" "$HEALTH_URL" < scripts/release.sh
          '''
        }
      }
    }

    stage('Smoke test') {
      when { expression { params.ACTION == 'deploy' } }
      steps {
        sshagent(credentials: ['app-server-deploy']) {
          sh '''
            ssh $SSH_OPTS deploy@$APP_HOST "curl -fsS http://127.0.0.1:8084/api/items?category=network" | tee smoke.json
            echo
            grep -q '"count":' smoke.json || { echo "smoke test failed"; exit 1; }
            echo "smoke test passed"
          '''
        }
      }
    }

    stage('Rollback') {
      when { expression { params.ACTION == 'rollback' } }
      steps {
        sshagent(credentials: ['app-server-deploy']) {
          sh 'ssh $SSH_OPTS deploy@$APP_HOST bash -s -- rollback "$APP_ROOT" "$HEALTH_URL" < scripts/release.sh'
        }
      }
    }
  }

  post {
    always {
      script {
        if (fileExists('reports/junit.xml')) {
          junit testResults: 'reports/junit.xml', allowEmptyResults: true
        }
        if (fileExists('reports/flake8.txt')) {
          recordIssues(tools: [flake8(pattern: 'reports/flake8.txt')])
        }
      }
      sh 'rm -rf build release.tgz smoke.json'
    }
  }
}
