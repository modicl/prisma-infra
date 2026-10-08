# prisma-infra — la infraestructura AWS de P.R.I.S.M.A. en Terraform

Describe todo lo que hoy corre en el Learner Lab (cuenta `447542120009`) para poder
levantarlo igual en otra cuenta cuando se agote el presupuesto. Se escribió el
2026-09-15 a partir de un inventario del lab real, y `terraform plan` con los
bloques `import` da **0 to destroy** contra esa cuenta: el código describe
exactamente lo que existe.

El manual de despliegue paso a paso (consola, para el equipo) está aparte:
https://claude.ai/artifact/JFoBrQ5kUWG1da1FY2C6mh. Este repo es la versión
automatizada de las fases de AWS de ese manual.

## Estado al 2026-10-08

- **Aplicado** (cuenta del lab `422304261446`): `01` a `06`, más `08-flujo-sfn.tf` (SQS + DLQ, Lambdas `starter` e `invoker`, Step Functions Standard,
  notificación S3 → SQS) y `11-postgres.tf` (RDS, una base por servicio). La notificación antigua S3 → Lambda `trigger` se retiró de `05-eventos.tf`.
- **Propuesto, sin aplicar** (`.tf.pendiente`, Terraform no los carga): `07-monitor` (monitor en vivo), `09-red-privada` (subredes privadas + NAT) y
  `10-kafka` (Kafka en EC2). El NAT no se aplicó porque consume el crédito del laboratorio.
- **Manual tras un apply en una cuenta nueva:** crear las 4 bases de datos y correr las migraciones (ver el encabezado de `11-postgres.tf`),
  subir las imágenes (`scripts/push-imagenes.ps1`; si `aws` no se resuelve en PowerShell, hacerlo desde Bash) y subir `desired_count` del servicio a 1.

## Qué cubre

| Archivo | Recursos |
|---|---|
| `01-cognito.tf` | User Pool, grupos `SUPERADMIN/ADMIN/TEACHER`, IdPs Google y Entra External ID, app client, dominio |
| `02-red.tf` | Security groups en cadena, ALB interno, target groups, listener y regla `/chat/*`, VPC Link |
| `03-ecs.tf` | 6 repos ECR, log group, cluster, task definition (6 contenedores), servicio |
| `04-apigw.tf` | HTTP API, JWT authorizer, integración al ALB, rutas `ANY` + `OPTIONS`, stage `$default` |
| `05-eventos.tf` | DynamoDB `chat_sessions`, bucket S3 + notificación, Lambdas `prisma-trigger` y `prisma-presignup` |
| `06-amplify.tf` | App Amplify conectada a GitHub + rama `main` |
| `data.tf` | Lo que cambia por cuenta: account id, `LabRole`, VPC y subnets por defecto |
| `imports-lab-447542120009.tf` | Adopta los recursos ya existentes en ESA cuenta. Borrar en una cuenta nueva |

## Qué NO cubre (manual en cada cuenta nueva)

1. **Imágenes Docker.** Cada cuenta tiene su propio registro ECR. Hay que hacer
   build + push de las 6 imágenes (o apuntar los secrets de GitHub Actions a la
   cuenta nueva y pushear a las ramas `cloud/aws/*`).
2. **Google Cloud Console y Azure.** El dominio de Cognito es único a nivel
   global, así que en la cuenta nueva cambia (`cognito_domain_prefix`) y con él
   la redirect URI. Hay que agregar la nueva en el OAuth client de Google y en el
   app registration de Entra. El output `cognito_redirect_uri_para_idps` la imprime.
3. **La conexión Amplify ↔ GitHub.** O se pasa un PAT en `github_token`, o se
   autoriza la app de GitHub desde la consola de Amplify después del apply.
4. **Datos.** Usuarios de Cognito (se registran de nuevo; entran como PENDING y se
   les asigna grupo), tablas de Postgres (`prisma migrate deploy` por repo), y lo
   que viva en Aiven.
5. **Postgres.** Sigue en Aiven, fuera de AWS. Solo cambia si se migra a RDS.

## Uso en el lab actual (validar / adoptar)

```powershell
# Credenciales del Learner Lab en ~/.aws/credentials (con session token)
terraform init
terraform plan -out=plan.tfplan      # debe decir "0 to destroy"
terraform apply plan.tfplan          # adopta los recursos al state; no crea nada nuevo
```

`terraform.tfvars` ya existe con los valores reales (gitignoreado, contiene secretos).
Después del primer apply, `imports-lab-447542120009.tf` se puede borrar: los
recursos ya están en el state.

## Migración a una cuenta nueva

Orden importa. Cada paso depende del anterior. Hay dos scripts en `scripts/`
que hacen la parte pesada (subir imágenes y verificar la cadena).

**0. Preparar**
- Credenciales nuevas en `~/.aws/credentials`.
- `rm imports-lab-447542120009.tf` y `rm terraform.tfstate*` (state de la cuenta vieja).
- `copy nuevo-lab.tfvars terraform.tfvars`. Ese archivo (gitignoreado) ya viene
  prellenado con todo lo que no depende de la cuenta AWS: secretos de Google y
  Entra, Aiven, `INTERNAL_TOKEN`, API key. Solo hay que completar las líneas
  marcadas `CAMBIAR` (`cognito_domain_prefix` y, opcional, `github_token`).
  Si no existe, partir de `terraform.tfvars.example`.

**1. Primera pasada**
```powershell
terraform init
terraform apply
```
Crea todo. El servicio ECS va a fallar al arrancar porque las imágenes no
existen todavía: es esperable.

**2. Imágenes**
```powershell
.\scripts\push-imagenes.ps1
```
Hace login a ECR, construye las 6 imágenes con `--platform linux/amd64` desde
la carpeta de cada repo (avisa si la rama activa no es la de despliegue), las
sube y fuerza el redeploy del servicio.

**3. Segunda pasada (URLs que recién existen)**
- Agregar `terraform output amplify_url` a `front_urls` en `terraform.tfvars`.
- `terraform apply` → actualiza callback/logout de Cognito y el CORS del gateway.

**4. Fuera de AWS**
- Google Console → OAuth client → Authorized redirect URIs → agregar
  `terraform output cognito_redirect_uri_para_idps`.
- Azure → App registration → Authentication → Redirect URIs → la misma.
- Amplify → conectar GitHub si no se pasó `github_token` → primer build.

**5. Verificar**
```powershell
.\scripts\verificar.ps1
```
Solo lectura. Revisa outputs, imágenes por tag, servicio ECS, target groups,
401 sin token, preflight CORS, callbacks de Cognito y build de Amplify. Cada
falla dice qué paso falta.

**6. Datos**
- `prisma migrate deploy` en users, docs, adminpanel, perfil contra la BD.
- Login con Google → asignar grupo `SUPERADMIN` en Cognito → volver a loguearse
  (el grupo entra al token recién en el próximo login) → INSERT en `users.usuarios`.

## Gotchas del Learner Lab (por qué el código es como es)

- **No se pueden crear roles IAM.** Todo usa `data.aws_iam_role.lab` (`LabRole`),
  en ambos roles de la task definition. La consola propone `ecsTaskExecutionRole`,
  que no existe.
- **Sin NAT Gateway.** El servicio ECS lleva `assign_public_ip = true`; sin eso la
  task no baja la imagen y muere con `CannotPullContainerError`.
- **El SCP niega `s3:GetBucketObjectLockConfiguration`.** El provider lo llama al
  leer cualquier `aws_s3_bucket`, así que el bucket se crea con `terraform_data` +
  CLI y el resto lo referencia por nombre.
- **Credenciales de ~4 h.** Un apply completo toma unos 10 minutos. Si vence a
  mitad, refrescar y volver a correr: Terraform retoma donde quedó.
- **`desired_count` se ignora después del primer apply**, para poder bajar el
  servicio a 0 por consola y ahorrar sin que Terraform lo suba de vuelta.
- **El state tiene los secretos** (client secrets de Google/Entra, `DATABASE_URL`).
  Está gitignoreado. Para compartirlo con el equipo, backend S3 dentro del mismo lab.

## Pendientes que este código deja visibles

- `chat_sessions` **no tiene TTL activado**, aunque el diseño dice 7 días. Falta
  confirmar qué atributo escribe `prisma_workflow` antes de declararlo.
- Las URLs de la app Amplify borrada (`staging.d2oct736k3ecuu`) siguen en Cognito y
  en el CORS. Quitarlas de `front_urls` en `terraform.tfvars` las limpia.
- La arquitectura objetivo (SQS + Step Functions + Bedrock + RDS) todavía no
  existe en ninguna cuenta. Cuando se construya, va en un `07-async.tf` escrito
  directo en Terraform, sin pasar por consola.
