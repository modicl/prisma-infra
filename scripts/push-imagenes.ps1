# Construye y sube las 6 imágenes al ECR de la cuenta ACTIVA en ~/.aws/credentials.
# Correr después del primer `terraform apply` (los repos ECR ya deben existir).
#
#   .\scripts\push-imagenes.ps1            # todas
#   .\scripts\push-imagenes.ps1 -Solo bff  # una
#
# Gotchas que este script resuelve:
#   - --platform linux/amd64: Fargate es X86_64; sin esto en una máquina ARM
#     la task muere con "exec format error".
#   - Cada repo se construye desde SU rama de despliegue (cloud/aws/*), no desde main.
#     El script no cambia de rama: avisa si la rama actual no es la esperada.
#   - Después de pushear fuerza un redeploy: el servicio apunta a :latest y ECS
#     no se entera solo de que el tag cambió.

param(
    [string]$Solo = "",
    [string]$Cluster = "prisma-cluster",
    [string]$Servicio = "prisma-app"
)

$ErrorActionPreference = "Stop"
$raiz = Resolve-Path (Join-Path $PSScriptRoot "..\..")

# nombre lógico -> carpeta, repo ECR, rama esperada
$imagenes = [ordered]@{
    bff        = @{ dir = "bff-prisma";              ecr = "bff-prisma";        rama = "main" }
    users      = @{ dir = "prisma-ms-users";         ecr = "api/users";         rama = "cloud/aws/users" }
    docs       = @{ dir = "prisma-ms-docs";          ecr = "api/msdocs";        rama = "cloud/aws/msdocs" }
    adminpanel = @{ dir = "prisma-adminpanel";       ecr = "api/adminpanel";    rama = "cloud/aws/admin" }
    perfil     = @{ dir = "prisma-ms-perfil-alumno"; ecr = "api/perfil-alumno"; rama = "cloud/aws/perfil" }
    workflow   = @{ dir = "prisma_workflow";         ecr = "prisma-workflow";   rama = "cloudnative" }
}

$cuenta = (aws sts get-caller-identity --query Account --output text)
$region = (aws configure get region); if (-not $region) { $region = "us-east-1" }
$base   = "$cuenta.dkr.ecr.$region.amazonaws.com"
Write-Host "Cuenta $cuenta  ->  $base" -ForegroundColor Cyan

aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $base
if (-not $?) { throw "docker login a ECR falló" }

foreach ($nombre in $imagenes.Keys) {
    if ($Solo -and $nombre -ne $Solo) { continue }
    $i   = $imagenes[$nombre]
    $dir = Join-Path $raiz $i.dir
    $ramaActual = (git -C $dir branch --show-current)
    if ($ramaActual -ne $i.rama) {
        Write-Warning "$($i.dir) está en '$ramaActual', se esperaba '$($i.rama)'. Se construye igual desde la rama actual."
    }
    $tag = "$base/$($i.ecr):latest"
    Write-Host "`n== $nombre  ($($i.dir) @ $ramaActual)  ->  $tag" -ForegroundColor Green
    docker build --platform linux/amd64 -t $tag $dir
    if (-not $?) { throw "build de $nombre falló" }
    docker push $tag
    if (-not $?) { throw "push de $nombre falló" }
}

Write-Host "`nForzando redeploy de $Cluster/$Servicio..." -ForegroundColor Cyan
aws ecs update-service --cluster $Cluster --service $Servicio --force-new-deployment --query "service.deployments[0].status" --output text
Write-Host "Listo. Seguir con:  .\scripts\verificar.ps1"

