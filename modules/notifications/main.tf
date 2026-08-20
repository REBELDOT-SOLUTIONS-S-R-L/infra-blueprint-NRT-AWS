# Module: notifications — SNS topics + SES sending identity/templates.

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws]
    }
  }
}

locals {
  name = "${var.name_prefix}-${var.boundary_name}"

  # CI sources this from a GitHub Environment variable (see terraform-apply.yml/
  # terraform-plan.yml), which resolves to "" rather than being absent when unset — treat
  # both null and "" as "no domain confirmed yet" so an empty CI variable doesn't try to
  # create an SES domain identity for domain "".
  ses_domain_set = var.ses_domain != null && var.ses_domain != ""
}

resource "aws_sns_topic" "this" {
  for_each = var.sns_topics

  name              = each.value.fifo ? "${local.name}-${each.key}.fifo" : "${local.name}-${each.key}"
  display_name      = each.value.display_name
  fifo_topic        = each.value.fifo
  kms_master_key_id = var.kms_key_arn

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-${each.key}"
  })
}

resource "aws_ses_domain_identity" "this" {
  count = local.ses_domain_set ? 1 : 0

  domain = var.ses_domain
}

resource "aws_ses_domain_dkim" "this" {
  count = local.ses_domain_set ? 1 : 0

  domain = aws_ses_domain_identity.this[0].domain
}

resource "aws_ses_template" "this" {
  for_each = var.ses_templates

  name    = "${local.name}-${each.key}"
  subject = each.value.subject_part
  html    = each.value.html_part
  text    = each.value.text_part
}
