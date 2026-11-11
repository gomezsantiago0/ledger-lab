terraform {
  required_version = ">= 1.11"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

resource "azurerm_log_analytics_workspace" "this" {
  count = var.logs_enabled ? 1 : 0

  name                = "log-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.1
  tags                = var.tags
}

# azurerm no permite elegir el modo del entorno y Azure lo crea en Express, que no admite
# secretos de Key Vault. Con azapi se pide WorkloadProfiles de forma explicita.
resource "azapi_resource" "environment" {
  type                      = "Microsoft.App/managedEnvironments@2026-07-01"
  name                      = "cae-${var.name}"
  parent_id                 = var.resource_group_id
  location                  = var.location
  tags                      = var.tags
  schema_validation_enabled = false

  body = {
    properties = {
      environmentMode  = "WorkloadProfiles"
      workloadProfiles = [{ name = "Consumption", workloadProfileType = "Consumption" }]
      appLogsConfiguration = var.logs_enabled ? {
        destination               = "log-analytics"
        logAnalyticsConfiguration = { customerId = azurerm_log_analytics_workspace.this[0].workspace_id }
      } : null
    }
  }

  sensitive_body = var.logs_enabled ? {
    properties = {
      appLogsConfiguration = {
        logAnalyticsConfiguration = { sharedKey = azurerm_log_analytics_workspace.this[0].primary_shared_key }
      }
    }
  } : null
}

# Identidad asignada por el usuario: existe, y tiene permisos, antes de crear la app.
# Con una identidad del sistema la primera revision fallaria al leer los secretos.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "secrets_reader" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.secrets_reader]
  create_duration = var.rbac_propagation_wait
}

resource "azurerm_container_app" "this" {
  name                         = "ca-${var.name}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azapi_resource.environment.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags
  depends_on                   = [time_sleep.rbac_propagation]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  dynamic "secret" {
    for_each = var.secret_ids
    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = azurerm_user_assigned_identity.app.id
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 8000
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    http_scale_rule {
      name                = "http"
      concurrent_requests = "20"
    }

    container {
      name   = "ledger"
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = var.environment_variables
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }

      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/healthz"
      }

      # Tolera el arranque en frio: reanudar la base en pausa puede tomar cerca de un minuto.
      startup_probe {
        transport               = "HTTP"
        port                    = 8000
        path                    = "/healthz"
        interval_seconds        = 10
        failure_count_threshold = 12
      }
    }
  }
}