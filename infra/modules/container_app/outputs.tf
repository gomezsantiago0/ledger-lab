output "url" {
  description = "URL publica HTTPS."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "environment_id" {
  description = "Id del entorno de Container Apps que usa la app."
  value       = azurerm_container_app.this.container_app_environment_id
}
