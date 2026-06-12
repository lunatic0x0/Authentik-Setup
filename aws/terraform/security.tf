###############################################################################
# Security group — strict. Only 80 (Let's Encrypt http-01) and 443 inbound.
# No SSH ever. Egress open (Authentik needs to reach Let's Encrypt, ghcr.io,
# Identity Center metadata, etc.).
###############################################################################

resource "aws_security_group" "idp" {
  name        = "authentik-idp-sg"
  description = "Authentik IdP - public 80/443 only, no SSH."
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = toset(var.allowed_admin_cidrs)

  security_group_id = aws_security_group.idp.id
  description       = "HTTPS for Authentik UI + SAML metadata"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = toset(var.allowed_admin_cidrs)

  security_group_id = aws_security_group.idp.id
  description       = "HTTP - Caddy uses this only for Lets Encrypt http-01 + redirect"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "egress" {
  security_group_id = aws_security_group.idp.id
  description       = "Egress to internet for pulls, ACME, AWS APIs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
