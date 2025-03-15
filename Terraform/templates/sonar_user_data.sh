#!/usr/bin/env bash
set -e
readonly SONAR_VERSION=${sonar_version}
readonly SONAR_DIR=/opt/sonarqube-$SONAR_VERSION
readonly SONAR_USER=sonar
readonly SONAR_GROUP=sonar
readonly SONAR_URL=https://binaries.sonarsource.com/Distribution/sonarqube

# Send the log output from this script to user-data.log, syslog, and the console
# From: https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

function log {
    local -r level="$1"
    local -r message="$2"
    local -r timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    >&2 echo -e "$timestamp [$level] $message"
}

function log_info {
    local -r message="$1"
    log "INFO" "$message"
}

function log_warn {
    local -r message="$1"
    log "WARN" "$message"
}

function log_error {
    local -r message="$1"
    log "ERROR" "$message"
}

## Referenced from https://github.com/actions/runner-images/
function reload_etc_environment() {
     # add `export ` to every variable of /etc/environment except PATH and eval the result shell script
     eval $(grep -v '^PATH=' /etc/environment | sed -e 's%^%export %')
     # handle PATH specially
     etc_path=$(get_etc_environment_variable PATH)
     export PATH="$PATH:$etc_path"
 }

 function get_etc_environment_variable() {
     local variable_name=$1

     grep "^$variable_name=" /etc/environment | sed -E "s%^$variable_name=\"?([^\"]+)\"?.*$%\1%"
 }

function add_etc_environment_variable() {
    local variable_name=$1
    local variable_value=$2

    echo "$variable_name=$variable_value" | sudo tee -a /etc/environment
}

function replace_etc_environment_variable() {
    local variable_name=$1
    local variable_value=$2

    # modify /etc/environment in place by replacing a string that begins with variable_name
    sudo sed -i -e "s%^$variable_name=.*$%$variable_name=$variable_value%" /etc/environment
}

function set_etc_environment_variable() {
    local variable_name=$1
    local variable_value=$2

    if grep "^$variable_name=" /etc/environment > /dev/null; then
        replace_etc_environment_variable $variable_name $variable_value
    else
        add_etc_environment_variable $variable_name $variable_value
    fi
}

function installPrerequisites() {
    log_info "Begin installing prerequisites"
    # Enable retry logic for apt up to 10 times
    echo "APT::Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries
    
    # Configure apt to always assume Y
    echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes
    
    echo 'vm.max_map_count=524288' | tee -a /etc/sysctl.d/99-sonarqube.conf
    echo 'fs.file-max=131072' | tee -a /etc/sysctl.d/99-sonarqube.conf

    # Documentation says to apply changes by running the below
    sysctl -p /etc/sysctl.d/99-sonarqube.conf

    echo sysctl vm.max_map_count
    
    apt-get update
    apt-get install jq unzip curl wget
    log_info "Successfully installed prerequisites"
}

function installJava() {
    log_info "Begin installing Java 17"
    # Add Adoptium PPA
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor > /usr/share/keyrings/adoptium.gpg
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/adoptium.list

    # Get all the updates from enabled repositories.
    apt-get update

    # Install Java 17 from PPA repositories
    apt-get -y install temurin-17-jdk=\*

    # Add extra permissions to be able execute command without sudo
    chmod -R 777 /usr/lib/jvm

    # Create Environment Variables
    set_etc_environment_variable JAVA_HOME /usr/lib/jvm/temurin-17-jdk-amd64
    set_etc_environment_variable  SONAR_JAVA_PATH /usr/lib/jvm/temurin-17-jdk-amd64/bin/java

    # Delete java repositories and keys
    rm -f /etc/apt/sources.list.d/adoptium.list
    rm -f /etc/apt/sources.list.d/zulu.list
    rm -f /usr/share/keyrings/adoptium.gpg
    rm -f /usr/share/keyrings/zulu.gpg

    reload_etc_environment
    log_info "Successfully installed Java"
}

function installPostgresql () {
    log_info "Begin installing PostgreSQL 14"
    REPO_URL="https://apt.postgresql.org/pub/repos/apt/"

    wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /usr/share/keyrings/postgresql.gpg
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] $REPO_URL $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

    # Install PostgreSQL
    echo "Install PostgreSQL"
    apt-get update
    apt-get install postgresql-14

    echo "Install libpq-dev"
    apt-get install libpq-dev

    rm /etc/apt/sources.list.d/pgdg.list
    rm /usr/share/keyrings/postgresql.gpg
    log_info "Done installing PostgreSQL"
}


function installSonarqubeCommunity() {
    log_info "Begin installing Sonarqube"
    # Setup a user to run the Sonarqube server
    /usr/sbin/groupadd -r $SONAR_GROUP 2>/dev/null
    /usr/sbin/useradd -c $SONAR_USER -r -s /bin/bash -d "$SONAR_DIR" -g $SONAR_GROUP $SONAR_USER 2>/dev/null

    echo "Downloading $SONAR_URL/sonarqube-$SONAR_VERSION.zip"
    # Download the zip file
    curl -4sSLo "/tmp/sonarqube.zip" "$SONAR_URL/sonarqube-$SONAR_VERSION.zip"

    # Unzip to Sonar base directory
    chmod 777 "/tmp/sonarqube.zip"
    unzip -qq -d "/opt" "/tmp/sonarqube.zip"

    log_info "Successfully installed Sonarqube"
}

function configureSql {
    log_info "Starting to configure postgresql schema"
    psql -c "CREATE SCHEMA IF NOT EXISTS sonarqube AUTHORIZATION ${database_user}; ALTER USER ${database_user} SET search_path TO sonarqube;" postgresql://${database_user}:${database_password}@${database_host}/${database_name}
    log_info "Done configuring postgresql schema"

}

function overwrite_db_configuration() {
  log_info "Starting to overwrite JDBC Configuration"
  sed -i -e "s|^#\(sonar.jdbc.username=\).*|\1${database_user}|" \
           -e "s|^#\(sonar.jdbc.password=\).*|\1${database_password}|" \
           -e "s|#sonar.jdbc.url=jdbc:postgresql://localhost/sonarqube?currentSchema=my_schema|sonar.jdbc.url=jdbc:postgresql://${database_host}/${database_name}?currentSchema=sonarqube|" "$SONAR_DIR/conf/sonar.properties"
  log_info "Done overwriting JDBC Configuration"
}

function overwrite_web_server_configuration() {
  log_info "Starting to overwrite sonar server configuration"
    ## Configure Web Server
    mkdir -p -m 777 /var/sonarqube/data /var/sonarqube/temp /usr/bin/sonar
    sed -i -e "s|#sonar.path.data=data|sonar.path.data=/var/sonarqube/data|" \
           -e "s|#sonar.path.temp=temp|sonar.path.temp=/var/sonarqube/temp|" \
           -e "s|#sonar.web.host=0.0.0.0|sonar.web.host=${local_ip_addr}|" \
           -e "s|#sonar.web.port=9000|sonar.web.port=8080|" \
           -e "s|#sonar.web.context=|sonar.web.context=/sonarqube|" \
           -e "s|#sonar.ce.javaAdditionalOpts=|sonar.ce.javaAdditionalOpts=-server|" \
           -e "s|#sonar.web.javaAdditionalOpts=|sonar.web.javaAdditionalOpts=-server|" $SONAR_DIR/conf/sonar.properties
    log_info "Done overwriting sonar server configuration"
}

function startWithSystemctlLoMem() {
#  sudo systemctl stop postgresql
#  sudo systemctl stop snap.amazon-ssm-agent.amazon-ssm-agent.service
#  sudo systemctl stop unattended-upgrades.service

#    ## Reduce the memory consumption in order to run on smaller EC2 instance
#    sed -i -e "s|#sonar.web.javaOpts=-Xmx512m -Xms128m -XX:+HeapDumpOnOutOfMemoryError|sonar.web.javaOpts=-Xmx512m -Xms64m -XX:+HeapDumpOnOutOfMemoryError|" \
#           -e "s|#sonar.ce.javaOpts=-Xmx512m -Xms128m -XX:+HeapDumpOnOutOfMemoryError|sonar.ce.javaOpts=-Xmx512m -Xms64m -XX:+HeapDumpOnOutOfMemoryError|" \
#           -e "s|#sonar.search.javaOpts=-Xmx512m -Xms512m -XX:MaxDirectMemorySize=256m -XX:+HeapDumpOnOutOfMemoryError|#sonar.search.javaOpts=-Xmx512m -Xms128m -XX:MaxDirectMemorySize=256m -XX:+HeapDumpOnOutOfMemoryError|" $SONAR_DIR/conf/sonar.properties

      sudo echo "[Unit]
                 Description=SonarQube service
                 After=syslog.target network.target

                 [Service]
                 Type=simple
                 User=$SONAR_USER
                 Group=$SONAR_GROUP
                 PermissionsStartOnly=true
                 ExecStart=/bin/nohup $SONAR_JAVA_PATH -Xms32m -Xmx32m -Djava.net.preferIPv4Stack=true -jar $SONAR_DIR/lib/sonar-application-$SONAR_VERSION.jar
                 StandardOutput=journal
                 LimitNOFILE=131072
                 LimitNPROC=8192
                 MemoryMax=640M
                 TimeoutStartSec=5
                 Restart=always
                 SuccessExitStatus=143

                 [Install]
                 WantedBy=multi-user.target" > /etc/systemd/system/sonarqube.service

      sudo systemctl enable sonarqube.service
      sudo systemctl start sonarqube.service
}

function startWithSystemctl() {
      sudo echo "[Unit]
                 Description=SonarQube service
                 After=syslog.target network.target

                 [Service]
                 Type=simple
                 User=$SONAR_USER
                 Group=$SONAR_GROUP
                 PermissionsStartOnly=true
                 ExecStart=/bin/nohup $SONAR_JAVA_PATH -Xms32m -Xmx32m -Djava.net.preferIPv4Stack=true -jar $SONAR_DIR/lib/sonar-application-$SONAR_VERSION.jar
                 StandardOutput=journal
                 LimitNOFILE=131072
                 LimitNPROC=8192
                 TimeoutStartSec=5
                 Restart=always
                 SuccessExitStatus=143

                 [Install]
                 WantedBy=multi-user.target" > /etc/systemd/system/sonarqube.service

      sudo systemctl enable sonarqube.service
      sudo systemctl start sonarqube.service
}

function startWithInitd () {
    sudo echo "#!/bin/sh
               #
               # rc file for SonarQube
               #
               # chkconfig: 345 96 10
               # description: SonarQube system (www.sonarsource.org)
               #
               ### BEGIN INIT INFO
               # Provides: sonar
               # Required-Start: $network
               # Required-Stop: $network
               # Default-Start: 3 4 5
               # Default-Stop: 0 1 2 6
               # Short-Description: SonarQube system (www.sonarsource.org)
               # Description: SonarQube system (www.sonarsource.org)
               ### END INIT INFO
               " > /etc/init.d/sonar

               sudo echo 'sudo -u sonar /usr/bin/sonar/sonar.sh $*' >> /etc/init.d/sonar

               sudo ln -s $SONAR_DIR/bin/linux-x86-64/sonar.sh /usr/bin/sonar
               sudo chmod 755 /etc/init.d/sonar
               sudo update-rc.d sonar defaults

               sudo service sonar start
}

function startSonarqube() {
  log_info "Starting Sonarqube Service"
  # Change Sonar base user
  sudo chown -R $SONAR_USER:$SONAR_GROUP $SONAR_DIR
  startWithSystemctl
  log_info "Successfully started Sonarqube Service"
}

function run {
  installPrerequisites
  
  installJava

  installPostgresql

  installSonarqubeCommunity

  configureSql

  overwrite_db_configuration

  overwrite_web_server_configuration

  startSonarqube
}

run