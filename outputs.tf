output "api_endpoint" {
  description = "Invoke URL del gateway. Es lo que va en VITE_BFF_URL y VITE_CHAT_API_URL."
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.pool.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.front.id
}

output "cognito_domain" {
  description = "Hosted UI. La redirect URI para Google Console y Azure es https://<este>/oauth2/idpresponse"
  value       = "${aws_cognito_user_pool_domain.hosted.domain}.auth.${local.region}.amazoncognito.com"
}

output "cognito_redirect_uri_para_idps" {
  value = "https://${aws_cognito_user_pool_domain.hosted.domain}.auth.${local.region}.amazoncognito.com/oauth2/idpresponse"
}

output "amplify_url" {
  description = "Agregar a front_urls y volver a aplicar (segunda pasada)."
  value       = "https://${aws_amplify_branch.main.branch_name}.${aws_amplify_app.front.default_domain}"
}

output "alb_dns_interno" {
  value = aws_lb.alb.dns_name
}

output "ecr_base" {
  description = "Prefijo para docker tag / push de las 6 imágenes."
  value       = local.ecr_base
}
