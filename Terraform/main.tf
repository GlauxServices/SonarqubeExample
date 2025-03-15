terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.90.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Owner = var.owner_tag
    }
  }
}

data "aws_caller_identity" "aws" {}

## Network Elements
resource "aws_vpc" "root_vpc" {
  cidr_block       = var.vpc_cidr
  enable_dns_hostnames = true

  tags = {
    Name = "Sonar VPC"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.root_vpc.id

  tags = {
    Name = "Sonar VPC - Internet Gateway"
  }
}

resource "aws_route_table" "gw_route_table" {
  vpc_id = aws_vpc.root_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "Sonar VPC route table"
  }
  depends_on = [aws_internet_gateway.gw]
}

resource "aws_subnet" "sonar_subnet" {
  for_each = var.aws_subnet_cidrs

  vpc_id = aws_vpc.root_vpc.id
  availability_zone = each.key
  cidr_block        = each.value
  map_public_ip_on_launch = true


  tags = {
    Name = "Sonar Subnet - ${each.key}"
  }
  depends_on = [aws_route_table.gw_route_table]
}

resource "aws_main_route_table_association" "main_association" {
  vpc_id         = aws_vpc.root_vpc.id
  route_table_id = aws_route_table.gw_route_table.id
}

resource "aws_route_table_association" "association" {
  for_each = aws_subnet.sonar_subnet
  route_table_id = aws_route_table.gw_route_table.id
  subnet_id      = aws_subnet.sonar_subnet[each.key].id
}

resource "aws_network_acl" "block_attach" {
  vpc_id = aws_vpc.root_vpc.id
  subnet_ids = [for subnet in aws_subnet.sonar_subnet : subnet.id ]

  ingress {
    protocol = -1
    rule_no  = 100
    action   = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    protocol   = -1
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name = "Sonar Network ACL"
  }
}

resource "aws_network_acl_association" "access_control_list" {
  for_each = aws_subnet.sonar_subnet
  network_acl_id = aws_network_acl.block_attach.id
  subnet_id      = aws_subnet.sonar_subnet[each.key].id
}

## Sonarqube Resources
resource "aws_security_group" "sonar_security_group" {
  vpc_id = aws_vpc.root_vpc.id
  name   = "Sonar Client SG"

  ## HTTPS port exposed to allow configuration/updates
  ingress {
    description = "Public HTTPS Port"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.hosted_cidr]
  }

  ## Port 80 exposed to allow configuration/updates
  ingress {
    description = "Public HTTP Port"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.hosted_cidr]
  }

  ## Sonar Hosting Port
  ingress {
    description = "Sonarqube Port"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.hosted_cidr]
  }

  ## Used to expose SSH
  ingress {
    description = "SSH from Client CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.client_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Sonar Client SG"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "sonar_instance" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.sonarqube_server_size
  iam_instance_profile = aws_iam_instance_profile.sonarqube_profile.name
  user_data_base64 = base64encode(templatefile("${path.module}/templates/sonar_user_data.sh", {
    sonar_version     = "25.3.0.104237"
    local_ip_addr     = var.sonarqube_private_ip
    database_name     = aws_db_instance.sonar_db.db_name
    database_host     = aws_db_instance.sonar_db.endpoint,
    database_user     = var.db_username,
    database_password = random_string.sonarqube_root_password.result
  }))
  key_name   = aws_key_pair.sonarqube_key.key_name
  monitoring = var.enhanced_monitoring_enabled

  subnet_id = aws_subnet.sonar_subnet["us-east-1a"].id
  vpc_security_group_ids = [aws_security_group.sonar_security_group.id, aws_security_group.postgresql.id]
  private_ip = var.sonarqube_private_ip

  depends_on = [aws_internet_gateway.gw]

  tags = {
    Name = "sonar-server"
  }
}

## RDS Configuration
resource "aws_security_group" "postgresql" {
  vpc_id = aws_vpc.root_vpc.id
  name = "PostgreSQL SG"

  ## Allows communication with the entire VPC
  ingress {
    description = "postgresql from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [ aws_vpc.root_vpc.cidr_block ]
  }

  ingress {
    description = "postgresql from Sonarqube SG"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    security_groups = [aws_security_group.sonar_security_group.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Postgresql SG"
  }
  depends_on = [aws_security_group.sonar_security_group]
}

resource "random_string" "sonarqube_root_password" {
  length  = 40
  special = false
}

resource "aws_db_instance" "sonar_db" {
  db_name = "SonarDB"
  identifier = "sonar-server"
  instance_class = var.db_instance_type
  allocated_storage = 20
  storage_type = "gp2"

  engine = "postgres"
  engine_version = "17"

  ## Encryption
  storage_encrypted = var.encrypt_db
  kms_key_id = var.encrypt_db ? aws_kms_key.encrypt_db[0].arn : null

  ## Monitoring
  monitoring_interval = var.enhanced_monitoring_enabled ? 60 : 0
  monitoring_role_arn = var.enhanced_monitoring_enabled ? aws_iam_role.cloudwatch_role[0].arn : null
  enabled_cloudwatch_logs_exports = var.enhanced_monitoring_enabled ? ["postgresql"] : []

  ## Backup
  backup_retention_period = var.enableBackup ? 5 : 0
  backup_window = "00:00-03:00"

  maintenance_window = "sat:04:00-sat:06:00"

  vpc_security_group_ids = [aws_security_group.postgresql.id]
  db_subnet_group_name = aws_db_subnet_group.sonar_db_subnet_group.name

  username = var.db_username
  password = random_string.sonarqube_root_password.result

  skip_final_snapshot = var.enable_final_snapshot ? false : true
  final_snapshot_identifier = "sonar-rds-snapshot"

  tags = {
    Name = "sonar-server"
    DatabaseName = "SonarDB"
  }
}

resource "aws_db_subnet_group" "sonar_db_subnet_group" {
  name = "sonardb_subnet_group"
  subnet_ids = [for subnet in aws_subnet.sonar_subnet : subnet.id]

  tags = {
    Name = "SonarDB Subnet Group"
  }
}

## IAM Configuration
#
# EC2 Instance
data "aws_iam_policy_document" "sonarqube_instance_profile_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    effect = "Allow"
  }
}

data "aws_iam_policy_document" "sonarqube_service_role_policy" {
  statement {
    effect = "Allow"
    actions = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.aws.account_id}:dbuser:${aws_db_instance.sonar_db.resource_id}/*"]
  }
}

resource "aws_iam_role" "sonarqube_to_rds" {
  name = "sonarqube-to-rds"
  assume_role_policy = data.aws_iam_policy_document.sonarqube_instance_profile_assume_role.json
  description = "Role for Sonarqube service"

  tags = {
    Name = "sonarqube-to-rds"
  }
}

resource "aws_iam_role_policy" "sonarqube_service_role_policy" {
  policy = data.aws_iam_policy_document.sonarqube_service_role_policy.json
  name = "sonarqube-allow-service-role-policy"
  role   = aws_iam_role.sonarqube_to_rds.id
}

resource "aws_iam_instance_profile" "sonarqube_profile" {
  name = "sonarqube_access"
  role = aws_iam_role.sonarqube_to_rds.id

  tags = {
    Name = "sonarqube-allow-rds"
  }
}

# Cloudwatch Role
data "aws_iam_policy_document" "cloudwatch_assume_role_policy_document" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    effect = "Allow"
  }
}

data "aws_iam_policy_document" "cloudwatch_role_policy_document" {
  statement {
    effect = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "cloudwatch_role" {
  count = var.enhanced_monitoring_enabled ? 1 : 0
  name = "cloudwatch_role"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_assume_role_policy_document.json
  description = "Role for Cloudwatch"

  tags = {
    Name = "cloudwatch_iam_role"
  }
}

resource "aws_iam_role_policy" "cloudwatch_access" {
  count = var.enhanced_monitoring_enabled ? 1 : 0
  name = "cloudwatch_access"
  role = aws_iam_role.cloudwatch_role[0].name
  policy = data.aws_iam_policy_document.cloudwatch_role_policy_document.json
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring_role_policy_attachment" {
  count = var.enhanced_monitoring_enabled ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSEnhancedMonitoringRole"
  role       = aws_iam_role.cloudwatch_role[0].name
}

## Security/Encryption
resource "tls_private_key" "tls_bootstrap_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "sonarqube_key" {
  key_name = "sonarqube-bootstrap-key"
  public_key = tls_private_key.tls_bootstrap_key.public_key_openssh

  tags = {
    Name = "sonarqube-bootstrap-key"
  }
}

resource "aws_kms_key" "encrypt_db" {
  count = var.encrypt_db ? 1 : 0
  tags = {
    Name = "sonarqube-db-encryption"
  }
}

data "aws_iam_policy_document" "kms_key_share_policy" {
  statement {
    sid = "Enable Basic KMS access"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    resources = var.encrypt_db ? [aws_kms_key.encrypt_db[0].arn] : []
  }
}

resource "aws_iam_role_policy" "kms_key_share_policy" {
  count = var.encrypt_db? 1 : 0
  policy = data.aws_iam_policy_document.kms_key_share_policy.json
  role   = aws_iam_role.sonarqube_to_rds.id
}