data "aws_caller_identity" "current" {}

//create vpc
resource "aws_vpc" "opensearch-domains-vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "opensearch-domains-vpc"
  }
}

//create subnet
resource "aws_subnet" "opensearch-domains-subnet" {
  vpc_id     = aws_vpc.opensearch-domains-vpc.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = false

  tags = {
    Name = "opensearch-domains-subnet"
  }
}

//create security group
resource "aws_security_group" "opensearch-domains-sg" {
  name        = "sgopensearch-${var.domain}"
  description = "Managed by Terraform"
  vpc_id      = aws_vpc.opensearch-domains-vpc.id

  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"

    cidr_blocks = [
      aws_vpc.opensearch-domains-vpc.cidr_block,
    ]
  }
}

//create aws_iam_service_linked_role
resource "aws_iam_service_linked_role" "aws_iam_service_linked_role" {
  aws_service_name = "opensearchservice.amazonaws.com"
}

//aws iam policy 
data "aws_iam_policy_document" "opensearch_domains_policy" {
  statement {
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["es:*"]
    resources = ["arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/${var.domain}/*"]
  }

}


data "aws_subnets" "private" {
  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
  filter {
    name   = "vpc-id"
    values = [aws_vpc.opensearch-domains-vpc.id]
  }
}

//cloudwatch logs
resource "aws_cloudwatch_log_group" "opensearch_log_group_index_slow_logs" {
  name              = "/aws/opensearch/${var.domain}/index-slow"
  retention_in_days = 14
}


resource "aws_cloudwatch_log_group" "opensearch_log_group_search_slow_logs" {
  name              = "/aws/opensearch/${var.domain}/search-slow"
  retention_in_days = 14
}


resource "aws_cloudwatch_log_group" "opensearch_log_group_es_application_logs" {
  name              = "/aws/opensearch/${var.domain}/es-application"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_resource_policy" "opensearch_log_resource_policy" {
  policy_name = "${var.domain}-domain-log-resource-policy"

  policy_document = <<CONFIG
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "es.amazonaws.com"
      },
      "Action": [
        "logs:PutLogEvents",
        "logs:PutLogEventsBatch",
        "logs:CreateLogStream"
      ],
      "Resource": [
        "${aws_cloudwatch_log_group.opensearch_log_group_index_slow_logs.arn}:*",
        "${aws_cloudwatch_log_group.opensearch_log_group_search_slow_logs.arn}:*",
        "${aws_cloudwatch_log_group.opensearch_log_group_es_application_logs.arn}:*"
      ],
      "Condition": {
          "StringEquals": {
              "aws:SourceAccount": "${data.aws_caller_identity.current.account_id}"
          },
          "ArnLike": {
              "aws:SourceArn": "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/${var.domain}"
          }
      }
    }
  ]
}
CONFIG
}

//opensearch master user
resource "random_password" "password" {
  length  = 32
  special = true
}

resource "aws_ssm_parameter" "opensearch_master_user" {
  name        = "/service/${var.service}/MASTER_USER"
  description = "opensearch_password for ${var.service} domain"
  type        = "SecureString"
  value       = "${var.master_user},${random_password.password.result}"
}

//create opensearch domains
resource "aws_opensearch_domain" "example" {
  domain_name    = var.domain
  engine_version = "OpenSearch_2.9"
  
  cluster_config {
    instance_type            = "m6g.large.search"
    instance_count           = var.instance_count
    dedicated_master_count   = 2
    dedicated_master_type    = "m6g.large.search"
    dedicated_master_enabled = true
    # zone_awareness_enabled   = var.zone_awareness_enabled
    # zone_awareness_config {
    #   availability_zone_count = var.zone_awareness_enabled ? length(locals.subnet_ids) : null
    # }
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = true
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = var.master_user
      master_user_password = random_password.password.result
    }
  }

  encrypt_at_rest {
    enabled = true
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 10
    volume_type = "gp3"
    throughput  = 125
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_log_group_index_slow_logs.arn
    log_type                 = "INDEX_SLOW_LOGS"
  }
  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_log_group_search_slow_logs.arn
    log_type                 = "SEARCH_SLOW_LOGS"
  }
  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_log_group_es_application_logs.arn
    log_type                 = "ES_APPLICATION_LOGS"
  }

  node_to_node_encryption {
    enabled = true
  }

  vpc_options {
    subnet_ids = [
      aws_subnet.opensearch-domains-subnet.id,
    ]

    security_group_ids = [aws_security_group.opensearch-domains-sg.id]
  }

  advanced_options = {
    "rest.action.multi.allow_explicit_index" = "true"
  }

  access_policies = data.aws_iam_policy_document.opensearch_domains_policy.json

  tags = {
    Domain = "OpensearchDomain"
  }

  depends_on = [aws_iam_service_linked_role.aws_iam_service_linked_role]
}