# ================================================================================
# Outputs
# ================================================================================
# api_gateway_endpoint is read by apply.sh to inject the base URL into the
# HTML template before the 04-webapp Terraform phase runs.
# ================================================================================

output "api_gateway_endpoint" {
  description = "HTTPS base URL for the Notes API (no trailing slash)"
  value       = "https://${oci_apigateway_gateway.notes.hostname}"
}

output "ocir_image_path" {
  description = "Full OCIR path of the deployed function image"
  value       = var.image_path
}

output "nosql_table_name" {
  description = "OCI NoSQL table name"
  value       = oci_nosql_table.notes.name
}
