# DevOps Assignment Results

## Table of Contents
- [Description](#description)
- [Deployed Resources](#deployed-resources)
- [Design Decisions](#design-decisions)
  - [Terraform Design](#terraform-design)
  - [Network Infrastructure](#network-infrastructure)
- [Deployment Process](#deployment-process)
  - [Terraform](#terraform)
  - [Verification](#verification)
- [Conclusion](#conclusion)

## Description
The assignment was to create a SonarQube instance on AWS using pre-existing AMIs, external RDS, and free-tier resources.
Security and accessibility concerns had to be taken into account. The accompanying code is provided in response to the
requirements.

## Deployed Resources
- Sonarqube EC2 instance - t2.micro
- Sonarqube RDS instance - db.t3.micro
- VPC
  - 2 subnets
  - Internet Gateway
  - Network Routing Table
  - Network Access Control List
  - 2 security groups
- 2 IAM roles
  - EC2 role for database access
  - Cloudwatch role
- Optional components for database encryption
- Optional components for detailed Cloudwatch monitoring

## Design Decisions

### Terraform Design
Initially, I attempted to use an existing AMI with Sonarqube pre-installed. However, none existed on the free tier, so
I instead wrote a user data shell to install prerequisite and install, configure, and start Sonarqube as a service. For 
a description of the functions in the script file, see the [User Data Script](#user-data-script) section below

### Network Infrastructure
As per the instructions, the networking infrastructure is contained in a single VPC. For brevity, the configuration has 
been simplified, but in Production this system should at a minimum be set up with a Bastion host in a public subnet 
with a Firewall, and both the server and the database should be in a private subnet behind a Network Address Translation
gateway. Generally, Sonarqube would also be hosted on https, but as that requires a TLS certificate, that is outside the
scope of this exercise.
Currently, the VPC contains two public subnets, one in us-east-1a and one in us-east-1b. The Sonarqube host is deployed
in the subnet in us-east-1a, and the database is deployed into a database subnet group spanning both, per RDS 
requirements. The database is assigned to a security group which limits its traffic to PostgreSQL traffic only - 
tcp on port 5432 to the CIDR block of the VPC only. This was done to make it available to additional VPC subnet groups, 
in case they will be added. The Sonarqube server is assigned to both the database security group, and a separate security
group that is configured to allow external traffic. Another option would be to limit the database security group
to receive ingress traffic only from the Sonarqube server's security group. This precludes other VPC elements having
future access, but further limits the accessibility of external sources for security reasons. The subnets are assigned
to a custom Network Routing table with a route to the Internet Gateway. I considered deploying the database to 
private subnets, but opted not to for the sake of time.

### Sonarqube Server
Sonarqube's documentation regarding their prerequisites states that the recommended minimum amount of RAM is 3GB
[link](https://docs.sonarsource.com/sonarqube-server/9.9/requirements/prerequisites-and-overview/). The RAM available
on a t2.micro, the only compute resource available for the free tier, is 1GB. AWS documentation claims that the t3.micro
is available for free tier in some regions [link](https://aws.amazon.com/free/?nc2=h_ql_pr_ft&all-free-tier.sort-by=item.additionalFields.SortRank&all-free-tier.sort-order=asc&awsf.Free%20Tier%20Types=*all&awsf.Free%20Tier%20Categories=categories%23compute),
however us-east-1 is not one of those, and the t3.micro still only has 1 GB of available RAM. In order to run with no
memory modifications, an instance of t2.medium or higher is recommended. The Sonarqube AMIs available on the AWS 
marketplace do not support Free Tier. The only free-license version required a minimum instance type of t2.medium. 
All other AMIs were licensed at a cost. As such, I opted to create my own off of the generic Canonical Ubuntu 22.04
image. To overcome the memory issues, the shell script has a function called startWithSystemctlLoMem, which is designed
to overwrite the default settings to reduce the memory allocation to Sonarqube. The modifications to the process include:
- Stopping unused services to reduce memory usage (postgres)
- Modifying heap allocations to the JVM for each Sonarqube process (web, compute, elasticsearch)
- Assigning a maximum memory to the service. This preserves enough functionality that the console still responds

#### Findings
- Limiting the memory allocation increases the usage of the CPU extremely
- When the memory is limited but heap is not modified, calls to the hosting service will cause thread starvation and
peg the CPU usage -> MemoryMax < 1536M
- Setting MemoryMax=768M or above on the service on a t2.micro EC2 instance will prevent SSH connections
- The service starts on a t2.small with MemoryMax either unset, or set greater than 1536M, but
interacting before the initial load stabilized caused a thread to crash, and the remaining memory and cpu were not 
sufficient to overcome the crash loop (thread starvation). When it did not get into the crash loop, it would serve
correctly
- Modifying the heap stack settings had minimal effect on the overall memory usage, but caused threads to crash faster.
The limits commented out in the sonar.properties are probably as tight as they can reasonably go.
- Reducing the heap limits for the Elasticsearch in any way lead to faster crash loops

## Deployment Process
Deployment consists of 
- Running the Terraform scripts [Terraform](#terraform)
- Verifying the deployed resources [Verification](#verification)

### Terraform
The Terraform modules are defined in the main.tf file. The project should build and generate resources, given following 
assumptions:

- The user will have Terraform and the AWS Cli v2 installed on their machines.
- AWS access keys and secret access keys will be provisioned on the machine as environment variables.
- The AWS provisioner user will have sufficient privileges to provision infrastructure in AWS Region US-East-1.

This code uses a single, default provider for all aws resources. This is by design. In the case of variable or multiple
providers, they should be specified per each module. However, in practice, defining modules when they can be inferred
leads to more developer mishaps and lost hours of debugging. Variables have been provided for commonly overridden values,
but all are defined here with defaults. Typically, defaults should be provided wherever possible to simplify automated
tasks. The generated passwords and keypair files are returned as outputs to allow the user to test connectivity.

#### Commands
The Terraform code uses standard commands. Running
```bash
terraform init
```
will initialize the repository
```bash
terraform plan
```
will show a plan of resources to be created
```bash
terraform apply
```
will create the resources and run the user data script, causing the VPC, the Sonarqube Database and the Server to be 
created.
```bash
terraform destroy
```
will decommission all resources

#### Input Variables
The input variables are defined in the variables.tf file

| variable                    | description                                   | type        | default                                                          |
|-----------------------------|-----------------------------------------------|-------------|------------------------------------------------------------------|
| aws_region                  | AWS region in which resource is created       | string      | "us-east-1"                                                      |
| vpc_cidr                    | The VPC CIDR block                            | string      | 192.168.0.0/16                                                   |
| client_cidr                 | The IP range for client virtual network       | string      | 0.0.0.0/0                                                        |
| aws_subnet_cidrs            | Subnet CIDRs per AWS availability zones       | map(string) | { us-east-1a = "192.168.1.0/24", us-east-1b = "192.168.2.0/24" } |
| db_username                 | PostgresSQL DB User                           | string      | sonar                                                            |
| enableBackup                | Whether the db will create automatic backups  | bool        | false                                                            |
| encrypt_db                  | Whether the db will be encrypted              | bool        | false                                                            |
| enhanced_monitoring_enabled | Whether or not to enable enhanced monitoring  | bool        | false                                                            |

#### Output Variables
The output variables are defined in the outputs.tf file

| output              | description                                  | sensitive |
|---------------------|----------------------------------------------|-----------|
| private_key_openssh | OpenSSH Private Key String                   | true      |
| private_key_pem     | PEM format Private Key String                | true      |
| sonarqube_endpoint  | The endpoint for the hosted Sonarqube server | false     |
| db_username         | Database Username                            | false     |
| db_password         | Database Password                            | true      |
| db_endpoint         | Database Endpoint                            | false     |

#### User Data Script
The user data script is included under the $/templates$ folder. It is included on the Sonarqube EC2 instance as an HCL
Template file. It contains the following functions:
- Logging
  - log
  - log_info
  - log_warn
  - log_error
- Environment Variable helpers
  - reload_etc_environment
  - get_etc_environment_variable
  - add_etc_environment_variable
  - replace_etc_environment_variable
  - set_etc_environment_variable
- Installation
  - installPrerequisites
  - installJava
  - installPostgresql
  - installSonarqubeCommunity
- Configuration
  - configureSql
  - overwrite_db_configuration
  - overwrite_web_server_configuration
- Start
  - startSonarqube
  - startWithSystemctl
  - startWithInitd
- Base
  - run

### Verification
Upon successful deployment of the Terraform code, the below steps are provided to verify correct execution.

#### Sonarqube Server Verification
Upon deployment, the Sonarqube Server should be hosting the Sonarqube service on port 8080 (HTTP) at their public IP 
address (http://<ip_address>:8080/sonarqube). The sonarqube_endpoint output contains the URL for the hosted service. 
After navigating to the host URL, a log-in screen should appear. The administrator credentials should be a username of 
Admin a password admin. From there, the server should be available for use.

#### Sonarqube Database Verification
As the database is only accessible through the Sonarqube server, it can be verified by running psql commands through
the SSH connection to the server. The configureSql function in the server script shows an example.



## Conclusion
The code as submitted will run correctly on a t2.small or larger EC2 instance. However, I was unable to reduce the 
memory requirements to be able to run on a t2.micro instance. At this time I am unaware of a setting that will reduce 
the memory consumption of a JVM thread without causing it to crash. The code submitted should satisfy the requirements,
if using the larger instance. I tested the network connectivity, the database connectivity and configuration, the
server connectivity, and I successfully got the server to run, to connect to the database, and to serve Sonarqube.
I changed the admin password. I created a new user. I created a project. I connected it to an on-premises project.
I ran an analysis ang got a successful result. I did not have time to fully test the logging or encryption behavior, 
and they may contain errors. I am confident that the rest will function as desired.