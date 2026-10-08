# Verifica la cadena completa después de aplicar y subir imágenes. Solo lectura.
# Cada línea dice OK / FALLA y qué revisar. Correr desde prisma-infra/.
#
#   .\scripts\verificar.ps1

$ErrorActionPreference = "Continue"
$fallas = 0

function Chequeo($nombre, [bool]$ok, $detalle) {
    if ($ok) { Write-Host "  OK     $nombre" -ForegroundColor Green }
    else     { Write-Host "  FALLA  $nombre  -> $detalle" -ForegroundColor Red; $script:fallas++ }
}

Write-Host "`n[1] Terraform outputs" -ForegroundColor Cyan
$out = terraform output -json | ConvertFrom-Json
$api     = $out.api_endpoint.value
$amplify = $out.amplify_url.value
Chequeo "api_endpoint presente" ([bool]$api) "terraform apply no terminó"
Write-Host "         API:     $api"
Write-Host "         Amplify: $amplify"
Write-Host "         Redirect URI para Google/Azure: $($out.cognito_redirect_uri_para_idps.value)"

Write-Host "`n[2] Task definition: imágenes por tag, no por digest" -ForegroundColor Cyan
$imgs = aws ecs describe-task-definition --task-definition prisma-bff --query "taskDefinition.containerDefinitions[].image" --output json | ConvertFrom-Json
$porDigest = @($imgs | Where-Object { $_ -like "*@sha256:*" })
Chequeo "6 imágenes con :latest" ($porDigest.Count -eq 0 -and $imgs.Count -eq 6) "hay $($porDigest.Count) por digest: un push nuevo no las cambiaría"

Write-Host "`n[3] Servicio ECS" -ForegroundColor Cyan
$svc = aws ecs describe-services --cluster prisma-cluster --services prisma-app --query "services[0]" --output json | ConvertFrom-Json
Chequeo "desired=$($svc.desiredCount) running=$($svc.runningCount)" ($svc.runningCount -ge 1) "ver eventos: aws ecs describe-services ... --query services[0].events[:5]"
$ip = $svc.networkConfiguration.awsvpcConfiguration.assignPublicIp
Chequeo "assignPublicIp=$ip" ($ip -eq "ENABLED") "sin IP pública la task no baja la imagen (no hay NAT en el lab)"

Write-Host "`n[4] Target groups" -ForegroundColor Cyan
foreach ($tg in "tg-prisma-bff", "tg-prisma-workflow") {
    $arn = aws elbv2 describe-target-groups --names $tg --query "TargetGroups[0].TargetGroupArn" --output text
    $estados = aws elbv2 describe-target-health --target-group-arn $arn --query "TargetHealthDescriptions[].TargetHealth.State" --output json | ConvertFrom-Json
    Chequeo "$tg -> $($estados -join ',')" (($estados -contains "healthy")) "health check /health; el workflow tarda ~2 min en quedar healthy"
}

Write-Host "`n[5] API Gateway + Cognito" -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -Uri "$api/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    Chequeo "sin token -> 401" $false "devolvió $($r.StatusCode): el authorizer no está en la ruta"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    Chequeo "sin token -> 401" ($code -eq 401) "devolvió $code"
}
try {
    $r = Invoke-WebRequest -Uri "$api/api/auth/me" -Method OPTIONS -UseBasicParsing -Headers @{ Origin = $amplify; "Access-Control-Request-Method" = "GET" } -ErrorAction Stop
    $acao = $r.Headers["Access-Control-Allow-Origin"]
    Chequeo "preflight OPTIONS -> $($r.StatusCode) con ACAO=$acao" ($r.StatusCode -lt 300 -and $acao -eq $amplify) "si ACAO está vacío, falta la segunda pasada con amplify_url en front_urls"
} catch {
    Chequeo "preflight OPTIONS" $false "devolvió $($_.Exception.Response.StatusCode.value__): falta la ruta OPTIONS con auth NONE o el origen no está en CORS"
}

Write-Host "`n[6] Cognito" -ForegroundColor Cyan
$pool = $out.cognito_user_pool_id.value
$urls = aws cognito-idp describe-user-pool-client --user-pool-id $pool --client-id $out.cognito_client_id.value --query "UserPoolClient.CallbackURLs" --output json | ConvertFrom-Json
Chequeo "callback de Amplify registrada" ($urls -contains "$amplify/auth/callback") "falta la segunda pasada: agregar amplify_url a front_urls y aplicar"
$idps = aws cognito-idp list-identity-providers --user-pool-id $pool --query "Providers[].ProviderName" --output json | ConvertFrom-Json
Chequeo "IdPs: $($idps -join ', ')" (($idps -contains "Google") -and ($idps -contains "MicrosoftEntraID")) "revisar 01-cognito.tf"

Write-Host "`n[7] Amplify" -ForegroundColor Cyan
$app = aws amplify list-apps --query "apps[?name=='prisma-front'] | [0]" --output json | ConvertFrom-Json
Chequeo "repo conectado: $($app.repository)" ([bool]$app.repository) "conectar GitHub desde la consola de Amplify"
$job = aws amplify list-jobs --app-id $app.appId --branch-name main --max-items 1 --query "jobSummaries[0].status" --output text 2>$null
Chequeo "último build main: $job" ($job -eq "SUCCEED") "sin build aún o falló: revisar en la consola"

Write-Host ""
if ($fallas -eq 0) { Write-Host "Todo OK. Falta solo lo manual: redirect URIs en Google/Azure, migraciones Prisma, grupo SUPERADMIN al primer usuario." -ForegroundColor Green }
else { Write-Host "$fallas chequeo(s) con falla. Ver README.md, sección 'Migración a una cuenta nueva'." -ForegroundColor Yellow }
