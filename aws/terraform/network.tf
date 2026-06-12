###############################################################################
# Network — single-AZ public subnet. Sufficient for a lab IdP.
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "authentik-idp-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "authentik-idp-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false # we attach an EIP explicitly
  tags = {
    Name = "authentik-idp-public-a"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = {
    Name = "authentik-idp-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# VPC flow logs — to CloudWatch, useful for detection telemetry later.
###############################################################################

resource "aws_cloudwatch_log_group" "flow" {
  count             = var.enable_vpc_flow_logs ? 1 : 0
  name              = "/aws/vpc/authentik-idp-flow"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_assume" {
  count = var.enable_vpc_flow_logs ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  count              = var.enable_vpc_flow_logs ? 1 : 0
  name               = "authentik-idp-flowlogs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume[0].json
}

data "aws_iam_policy_document" "flow_inline" {
  count = var.enable_vpc_flow_logs ? 1 : 0
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  count  = var.enable_vpc_flow_logs ? 1 : 0
  name   = "authentik-idp-flowlogs"
  role   = aws_iam_role.flow[0].id
  policy = data.aws_iam_policy_document.flow_inline[0].json
}

resource "aws_flow_log" "this" {
  count           = var.enable_vpc_flow_logs ? 1 : 0
  iam_role_arn    = aws_iam_role.flow[0].arn
  log_destination = aws_cloudwatch_log_group.flow[0].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.this.id
}
