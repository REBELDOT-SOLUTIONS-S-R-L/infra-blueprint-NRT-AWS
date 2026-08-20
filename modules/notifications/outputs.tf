# Module: notifications — outputs consumed by environments/*

output "sns_topic_arns" {
  value       = { for k, t in aws_sns_topic.this : k => t.arn }
  description = "Map of topic name (matching var.sns_topics' keys) to created SNS topic ARN"
}

output "ses_domain_identity_arn" {
  value       = try(aws_ses_domain_identity.this[0].arn, null)
  description = "ARN of the SES domain identity, if ses_domain is set"
}

output "ses_dkim_tokens" {
  value       = try(aws_ses_domain_dkim.this[0].dkim_tokens, null)
  description = "DKIM tokens to publish as CNAME records in the sending domain's DNS — this repo doesn't control that DNS zone, so these need to be handed to whoever does"
}

output "ses_template_names" {
  value       = { for k, t in aws_ses_template.this : k => t.name }
  description = "Map of template name to created SES template name"
}
