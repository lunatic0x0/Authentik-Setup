###############################################################################
# EC2 — Ubuntu 24.04 Noble, matches MITRE ER8 Linux fleet.
###############################################################################

# Canonical's official Noble 24.04 amd64 AMI
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "random_password" "pg" {
  length  = 36
  special = false
}

resource "random_password" "secret_key" {
  length  = 60
  special = false
}

resource "aws_eip" "this" {
  domain = "vpc"
  tags = {
    Name = "authentik-idp-eip"
  }
}

locals {
  # sslip.io expects dashes in the IP, e.g., 13-49-1-5.sslip.io
  eip_dashed         = replace(aws_eip.this.public_ip, ".", "-")
  computed_hostname  = "${local.eip_dashed}.sslip.io"
  authentik_hostname = var.authentik_hostname_override != "" ? var.authentik_hostname_override : local.computed_hostname

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    authentik_tag      = var.authentik_image_tag
    authentik_hostname = local.authentik_hostname
    pg_password        = random_password.pg.result
    secret_key         = random_password.secret_key.result
  })
}

resource "aws_instance" "idp" {
  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.idp.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  # Temporary public IP so cloud-init has internet immediately; once
  # aws_eip_association.this attaches, the EIP replaces it.
  associate_public_ip_address = true

  user_data                   = local.user_data
  user_data_replace_on_change = true

  # IMDSv2 required — blocks SSRF-driven creds theft.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  # Encrypted root volume.
  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags = {
      Name = "authentik-idp-root"
    }
  }

  monitoring = var.enable_detailed_monitoring

  tags = {
    Name = "authentik-idp"
  }

  lifecycle {
    ignore_changes = [ami] # don't churn on AMI refresh — bump explicitly
  }
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.idp.id
  allocation_id = aws_eip.this.id
}
