variable "owner_tag" {
  description = "Set owner to tag AWS resources"
  type = string
  default = "DevOps-Assessment"
}

variable "aws_region" {
  description = "AWS region in which resource is created"
  type = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  description = "The VPC CIDR block"
  type        = string
  default = "192.168.0.0/16"
}

## Defaulted to open CIDR for test purposes.
# HIGHLY RECOMMENDED TO OVERRIDE WITH CUSTOMER IP RANGE
variable "client_cidr" {
  description = "The IP range for client virtual network"
  type = string
  default = "0.0.0.0/0"
}
## Defaulted to open CIDR for test purposes.
# If the Sonarqube instance is meant to be publicly accessible, 0.0.0.0/0
# Otherwise, set with appropriate value
variable "hosted_cidr" {
  description = "The IP range for Sonarqube client hosting"
  type = string
  default = "0.0.0.0/0"
}

variable "aws_subnet_cidrs" {
  description = "Subnet CIDRs per AWS availability zones"
  type = map(string)
  default = {
    us-east-1a = "192.168.1.0/24"
    us-east-1b = "192.168.2.0/24"
  }
}

variable "sonarqube_server_size" {
  description = "Instance type for Sonarqube server host"
  type = string
  default = "t2.medium"
}

variable "sonarqube_private_ip" {
  description = "Configure Sonarqube Server Private IP"
  type = string
  default = "192.168.1.11"
}

variable "db_instance_type" {
  description = "Instance type for Sonarqube server host"
  type = string
  default = "db.t3.micro"
}

variable "db_username" {
  description = "PostgresSQL DB User"
  type = string
  default = "sonar"
}

variable "enable_final_snapshot" {
  description = "Enable final snapshot of database on termination"
  type = bool
  default = false
}

variable "enableBackup" {
  description = "Whether the db will create automatic backups"
  type = bool
  default = false
}

variable "encrypt_db" {
  description = "Whether the db will be encrypted"
  type = bool
  default = false
}

variable "enhanced_monitoring_enabled" {
  description = "Whether or not to enable enhanced monitoring"
  type = bool
  default = false
}