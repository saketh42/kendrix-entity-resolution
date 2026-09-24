resource "snowflake_database" "kendrix" {
  name = "KENDRIX"
}

# RAW: source data as received (all VARCHAR, never edited).
resource "snowflake_schema" "raw" {
  database = snowflake_database.kendrix.name
  name     = "RAW"
}

# STAGING: cleaned and standardised data.
resource "snowflake_schema" "staging" {
  database = snowflake_database.kendrix.name
  name     = "STAGING"
}

# CURATED: matching outputs and master data.
resource "snowflake_schema" "curated" {
  database = snowflake_database.kendrix.name
  name     = "CURATED"
}

# AUDIT: evidence, review queue and run log.
resource "snowflake_schema" "audit" {
  database = snowflake_database.kendrix.name
  name     = "AUDIT"
}
