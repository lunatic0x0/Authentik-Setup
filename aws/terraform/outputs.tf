output "elastic_ip" {
  description = "Public IP of the Authentik IdP host."
  value       = aws_eip.this.public_ip
}

output "authentik_hostname" {
  description = "Public hostname Caddy issues a Let's Encrypt cert for. Use this when wiring AWS Identity Center."
  value       = local.authentik_hostname
}

output "authentik_admin_url" {
  description = "Admin UI URL (available ~3-5 minutes after apply, once Caddy has issued the cert)."
  value       = "https://${local.authentik_hostname}/if/admin/"
}

output "authentik_initial_setup_url" {
  description = "Initial setup URL — only works once. Visit it first to create akadmin."
  value       = "https://${local.authentik_hostname}/if/flow/initial-setup/"
}

output "ssm_session_command" {
  description = "Open a shell on the EC2 (no SSH needed) — requires the AWS Session Manager plugin locally."
  value       = "aws ssm start-session --target ${aws_instance.idp.id} --region ${var.aws_region}"
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.idp.id
}

output "saml_metadata_url_template" {
  description = "Once you create a SAML Provider in Authentik, its metadata URL follows this pattern. Replace <pk> with the provider primary key."
  value       = "https://${local.authentik_hostname}/api/v3/providers/saml/<pk>/metadata/?download"
}
