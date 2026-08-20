# Module: notifications — input variables
# SNS / SES: push, email, in-app, marketing notifications (see ARCHITECTURE.md's target stack).
# Delivers the output of NBA/NBO offer detection and fraud alerts to the customer-facing
# channels — this module only provisions the topics/identities, not notification content
# (subject lines, offer copy) beyond template scaffolding, which stays data engineering's/
# marketing's concern.
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1).

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Boundary these resources are deployed into — \"nrt-processing\" by default, since Flink/Lambda are the intended publishers, kept as a variable for naming/tag consistency"
  default     = "nrt-processing"
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN to encrypt SNS topics at rest. Null uses the AWS-managed default key — global/kms CMKs are out of scope for this round, matching the same deferral made elsewhere (see modules/networking, modules/msk, modules/elasticache)."
  default     = null
}

variable "sns_topics" {
  description = "Map of topic name => definition. Empty by default — populate per real notification channel needed, e.g. { \"nba-offer-push\" = {}, \"fraud-alert\" = {} }."
  type = map(object({
    display_name = optional(string, "")
    fifo         = optional(bool, false)
  }))
  default = {}
}

variable "ses_domain" {
  type        = string
  description = "Verified sending domain for SES (e.g. \"notifications.org.example.com\"). Null skips SES domain identity creation entirely — never invent a placeholder domain, this must come from whoever owns the organization's actual sending domain/DNS."
  default     = null
}

variable "ses_templates" {
  description = "Map of template name => SES email template. Empty by default — actual copy (subject lines, offer terms, marketing content) is owned by whoever owns customer-facing messaging, not invented here."
  type = map(object({
    subject_part = string
    html_part    = string
    text_part    = string
  }))
  default = {}
}
