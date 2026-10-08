# Hosting del SPA. Conectado a GitHub: cada push a main reconstruye.

resource "aws_amplify_app" "front" {
  name       = "${var.nombre}-front"
  platform   = "WEB"
  repository = var.github_repo_front
  # Solo se usa al crear la app; Amplify no lo devuelve, así que un import
  # no muestra diff aunque no lo tengas.
  access_token = var.github_token

  enable_branch_auto_build = false

  # npm 11 arriba de la imagen (trae npm 10): el lock se generó con 11 y
  # npm 10 falla con EUSAGE por las peers de @emnapi.
  build_spec = <<-EOT
    version: 1
    frontend:
      phases:
        preBuild:
          commands:
            - npm i -g npm@11
            - npm ci --cache .npm --prefer-offline
        build:
          commands:
            - npm run build
      artifacts:
        baseDirectory: dist
        files:
          - "**/*"
      cache:
        paths:
          - .npm/**/*
          - node_modules/**/*
  EOT

  # Fallback de SPA. Tiene que ser 200 (rewrite), nunca 301: un redirect
  # destruye el ?code= con que vuelve Cognito. Y NO puede ser /<*>: esa
  # fuente captura /assets/*.js y devuelve index.html como text/html ->
  # página en blanco. La regex excluye extensiones de asset.
  custom_rule {
    source = "</^[^.]+$|\\.(?!(css|gif|ico|jpg|js|png|txt|svg|woff|woff2|ttf|map|json)$)([^.]+$)/>"
    target = "/index.html"
    status = "200"
  }

  # Estas variables PISAN a .env.production (Vite: shell > archivo).
  environment_variables = {
    VITE_BFF_URL              = aws_apigatewayv2_api.api.api_endpoint
    VITE_CHAT_API_URL         = aws_apigatewayv2_api.api.api_endpoint
    VITE_COGNITO_USER_POOL_ID = aws_cognito_user_pool.pool.id
    VITE_COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.front.id
    VITE_COGNITO_DOMAIN       = "${aws_cognito_user_pool_domain.hosted.domain}.auth.${local.region}.amazoncognito.com"
  }
}

resource "aws_amplify_branch" "main" {
  app_id      = aws_amplify_app.front.id
  branch_name = "main"
  stage       = "PRODUCTION"
  framework   = "Web"

  enable_auto_build = true
  ttl               = "5"
}
