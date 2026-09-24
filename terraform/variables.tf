variable "snowflake_organization" {
  type        = string
  description = "Snowflake organization name"
}

variable "snowflake_account" {
  type        = string
  description = "Snowflake account name"
}

variable "snowflake_user" {
  type        = string
  description = "Terraform service user"
}

variable "snowflake_private_key" {
  type        = string
  description = "Snowflake RSA private key"
  sensitive   = true
}