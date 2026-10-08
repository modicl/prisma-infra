# Emisor único de identidad. Los grupos del pool SON los roles; la ausencia
# de grupo es el rol PENDING (sin acceso), que no existe como grupo a propósito.

resource "aws_cognito_user_pool" "pool" {
  name                = var.cognito_pool_name
  deletion_protection = "ACTIVE"
  user_pool_tier      = "ESSENTIALS"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OFF"

  username_configuration {
    case_sensitive = false
  }

  password_policy {
    minimum_length                   = 8
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  sign_in_policy {
    allowed_first_auth_factors = ["PASSWORD"]
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
    recovery_mechanism {
      name     = "verified_phone_number"
      priority = 2
    }
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  # Tenant. Mutable para que un admin pueda mover a un docente de colegio;
  # el valor nuevo entra al token recién en el próximo login.
  schema {
    name                = "colegioId"
    attribute_data_type = "String"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  # Allowlist de correos. Desconectada desde 2026-09-02 (var.allowlist_activa):
  # el registro es abierto y el rol PENDING hace el control.
  dynamic "lambda_config" {
    for_each = var.allowlist_activa ? [1] : []
    content {
      pre_sign_up = aws_lambda_function.presignup.arn
    }
  }

  lifecycle {
    # Borrar el pool borra los usuarios y sus vínculos federados.
    prevent_destroy = true
  }
}

# --- Roles ------------------------------------------------------------------
# Cognito además crea solo un grupo por cada IdP federado
# (<poolId>_Google, <poolId>_MicrosoftEntraID). NO son roles: los guards
# resuelven por lista blanca sobre estos tres.

resource "aws_cognito_user_group" "superadmin" {
  user_pool_id = aws_cognito_user_pool.pool.id
  name         = "SUPERADMIN"
  description  = "Gestion multi-colegio"
  precedence   = 1
}

resource "aws_cognito_user_group" "admin" {
  user_pool_id = aws_cognito_user_pool.pool.id
  name         = "ADMIN"
  description  = "Administrador de colegio"
  precedence   = 2
}

resource "aws_cognito_user_group" "teacher" {
  user_pool_id = aws_cognito_user_pool.pool.id
  name         = "TEACHER"
  description  = "Docente"
  precedence   = 3
}

# --- Proveedores federados --------------------------------------------------

resource "aws_cognito_identity_provider" "google" {
  user_pool_id  = aws_cognito_user_pool.pool.id
  provider_name = "Google"
  provider_type = "Google"

  # Los campos que no son client_id/secret/scopes los completa Cognito;
  # se declaran igual para que el plan no muestre diff.
  provider_details = {
    client_id                     = var.google_client_id
    client_secret                 = var.google_client_secret
    authorize_scopes              = "profile email openid"
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  # email_verified es necesario: sin él Cognito no confía en el correo
  # y el usuario federado queda sin verificar.
  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub"
  }
}

resource "aws_cognito_identity_provider" "entra" {
  user_pool_id  = aws_cognito_user_pool.pool.id
  provider_name = "MicrosoftEntraID"
  provider_type = "OIDC"

  provider_details = {
    client_id                     = var.entra_client_id
    client_secret                 = var.entra_client_secret
    authorize_scopes              = "openid profile email"
    attributes_request_method     = "GET"
    attributes_url_add_attributes = "false"
    # Entra External ID firma SIEMPRE con el GUID como subdominio, aunque el
    # tenant tenga nombre. Cognito compara el issuer como string exacto.
    oidc_issuer = "https://${var.entra_tenant_id}.ciamlogin.com/${var.entra_tenant_id}/v2.0"
  }

  attribute_mapping = {
    email    = "email"
    name     = "name"
    username = "sub"
  }
}

# --- App client (público, sin secret: SPA con PKCE) -------------------------

resource "aws_cognito_user_pool_client" "front" {
  name         = "${var.nombre}-front"
  user_pool_id = aws_cognito_user_pool.pool.id

  # Sin generate_secret: la SPA usa PKCE. No declararlo (ni en false) porque
  # el provider lo trata como forces replacement y cambiaría el Client ID.
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
  auth_session_validity         = 3

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  supported_identity_providers = [
    "COGNITO",
    aws_cognito_identity_provider.google.provider_name,
    aws_cognito_identity_provider.entra.provider_name,
  ]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]

  callback_urls = local.callback_urls
  logout_urls   = local.logout_urls

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 5
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  read_attributes = [
    "address", "birthdate", "custom:colegioId", "email", "email_verified",
    "family_name", "gender", "given_name", "locale", "middle_name", "name",
    "nickname", "phone_number", "phone_number_verified", "picture",
    "preferred_username", "profile", "updated_at", "website", "zoneinfo",
  ]
  write_attributes = [
    "address", "birthdate", "custom:colegioId", "email", "family_name",
    "gender", "given_name", "locale", "middle_name", "name", "nickname",
    "phone_number", "picture", "preferred_username", "profile", "updated_at",
    "website", "zoneinfo",
  ]
}

resource "aws_cognito_user_pool_domain" "hosted" {
  domain                = var.cognito_domain_prefix
  user_pool_id          = aws_cognito_user_pool.pool.id
  managed_login_version = 2
}
