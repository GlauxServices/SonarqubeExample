output "private_key_openssh" {
  description = "OpenSSH Private Key String"
  value = tls_private_key.tls_bootstrap_key.private_key_openssh
  sensitive = true
}

output "private_key_pem" {
  description = "PEM format Private Key String"
  value = tls_private_key.tls_bootstrap_key.private_key_pem
  sensitive = true
}

output "sonarqube_endpoint" {
  description = "The endpoint for the hosted Sonarqube server"
  value = "http://${aws_instance.sonar_instance.public_ip}:8080/sonarqube"
}

output "db_username" {
  description = "Database Username"
  value = var.db_username
}

output "db_password" {
  description = "Database Password"
  value = random_string.sonarqube_root_password.result
  sensitive = true
}

output "db_endpoint" {
  description = "Database Endpoint"
  value = aws_db_instance.sonar_db.endpoint
}