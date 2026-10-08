# Único recurso expuesto a Internet. Valida el JWT de Cognito en el borde
# y manda todo por el VPC Link al ALB interno, que rutea por path.

resource "aws_apigatewayv2_api" "api" {
  name          = "${var.nombre}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins     = local.cors_origins
    allow_methods     = ["*"]
    allow_headers     = ["authorization", "content-type"]
    allow_credentials = false
    max_age           = 86400
  }
}

# Sin scopes en las rutas: es la condición para que el authorizer acepte
# ID tokens, que es lo que manda el front (el BFF necesita email y name).
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.api.id
  name             = "cognito-${var.nombre}"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.front.id]
    # Sin barra final ni /.well-known: API Gateway agrega el sufijo solo.
    issuer = "https://${aws_cognito_user_pool.pool.endpoint}"
  }
}

# Una sola integración al LISTENER del ALB: el ruteo /chat vs /api lo hace el ALB.
resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.api.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.link.id
  integration_uri    = aws_lb_listener.http.arn
  # 30 s es el máximo de HTTP API: la razón de fondo del diseño asíncrono
  # (polling + cola) para un flujo que dura minutos.
  timeout_milliseconds = 30000
}

resource "aws_apigatewayv2_route" "api" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "ANY /api/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "chat" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "ANY /chat/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# El preflight del navegador no lleva token. Sin estas rutas, ANY /{proxy+}
# captura el OPTIONS, pasa por el authorizer y el CORS devuelve 401.
resource "aws_apigatewayv2_route" "api_options" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "OPTIONS /api/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "NONE"
}

resource "aws_apigatewayv2_route" "chat_options" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "OPTIONS /chat/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "NONE"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}
