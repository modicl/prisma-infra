# Flujo event-driven: ms-docs escribe en S3 -> Lambda prisma-trigger ->
# POST /chat/internal/run/{id} al workflow a través del ALB interno.
# El orden DynamoDB -> S3 en ms-docs es obligatorio: la Lambda espera
# encontrar la sesión ya creada.

resource "aws_dynamodb_table" "sessions" {
  name         = "chat_sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"

  attribute {
    name = "session_id"
    type = "S"
  }

  # Pendiente: activar TTL. El código y la doc hablan de 7 días, pero en el
  # lab actual está desactivado. Falta confirmar qué atributo escribe el
  # workflow antes de declararlo acá.
}

# El nombre lleva el account id porque el corto ya existía en otra cuenta.
#
# NO es un aws_s3_bucket: el SCP del Learner Lab niega
# s3:GetBucketObjectLockConfiguration, que el provider llama al leer el
# bucket, y el plan muere con AccessDenied. Se crea por CLI (idempotente) y
# el resto de recursos lo referencian por nombre.
locals {
  bucket_workflow     = "${var.nombre}-workflow-${local.account_id}"
  bucket_workflow_arn = "arn:aws:s3:::${local.bucket_workflow}"
}

resource "terraform_data" "bucket_workflow" {
  input = local.bucket_workflow

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    command     = "aws s3api head-bucket --bucket ${local.bucket_workflow} 2>$null; if (-not $?) { aws s3api create-bucket --bucket ${local.bucket_workflow} --region ${local.region} }"
  }
}

resource "aws_s3_bucket_public_access_block" "workflow" {
  bucket                  = local.bucket_workflow
  depends_on              = [terraform_data.bucket_workflow]
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Lambda trigger (S3 -> workflow) ---------------------------------------
# El código vive en prisma_workflow/lambda/ y debe seguir siendo stdlib puro
# (sin boto3) por cold start. Se empaqueta desde ahí, no se copia.

data "archive_file" "trigger" {
  type        = "zip"
  output_path = "${path.module}/.build/prisma-trigger.zip"

  source {
    content  = file("${path.module}/../prisma_workflow/lambda/trigger_handler.py")
    filename = "lambda_function.py"
  }
}

resource "aws_cloudwatch_log_group" "trigger" {
  name = "/aws/lambda/${var.nombre}-trigger"
}

resource "aws_lambda_function" "trigger" {
  function_name = "${var.nombre}-trigger"
  role          = data.aws_iam_role.lab.arn
  runtime       = "python3.12"
  handler       = "lambda_function.handler"
  architectures = ["x86_64"]
  timeout       = 60
  memory_size   = 128

  filename         = data.archive_file.trigger.output_path
  source_code_hash = data.archive_file.trigger.output_base64sha256

  # En la VPC para alcanzar el ALB interno.
  vpc_config {
    subnet_ids         = local.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      BACKEND_INTERNAL_URL = "http://${aws_lb.alb.dns_name}" # con http://, sin él falla en silencio
      INTERNAL_TOKEN       = var.internal_token
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.trigger.name
  }
}

# La notificación jobs/ -> Lambda `trigger` (camino antiguo) se reemplazó por jobs/ -> SQS -> Step Functions
# (ver 08-flujo-sfn.tf). S3 admite una sola configuración de notificaciones por bucket. La Lambda `trigger` queda
# creada pero sin disparador, por si hay que volver atrás (la reversa está descrita en 08-flujo-sfn.tf).

# --- Lambda presignup (allowlist de correos, opcional) ----------------------
# Existe siempre; se conecta al pool solo si var.allowlist_activa = true.

data "archive_file" "presignup" {
  type        = "zip"
  output_path = "${path.module}/.build/prisma-presignup.zip"

  source {
    content  = file("${path.module}/../prisma_workflow/lambda/presignup_handler.py")
    filename = "presignup_handler.py"
  }
}

resource "aws_cloudwatch_log_group" "presignup" {
  name = "/aws/lambda/${var.nombre}-presignup"
}

resource "aws_lambda_function" "presignup" {
  function_name = "${var.nombre}-presignup"
  role          = data.aws_iam_role.lab.arn
  runtime       = "python3.12"
  handler       = "presignup_handler.handler"
  architectures = ["x86_64"]
  timeout       = 5
  memory_size   = 128

  filename         = data.archive_file.presignup.output_path
  source_code_hash = data.archive_file.presignup.output_base64sha256

  environment {
    variables = {
      ALLOWED_EMAILS = join(",", var.allowlist_correos)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.presignup.name
  }
}

resource "aws_lambda_permission" "cognito_invoca_presignup" {
  count = var.allowlist_activa ? 1 : 0

  statement_id  = "AllowCognitoPreSignUp"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presignup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.pool.arn
}
