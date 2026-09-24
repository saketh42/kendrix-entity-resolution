output "kendrix_database" {
  value = snowflake_database.kendrix.name
}

output "raw_schema" {
  value = snowflake_schema.raw.name
}

output "staging_schema" {
  value = snowflake_schema.staging.name
}

output "curated_schema" {
  value = snowflake_schema.curated.name
}

output "audit_schema" {
  value = snowflake_schema.audit.name
}
