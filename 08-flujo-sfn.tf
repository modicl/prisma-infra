# ──────────────────────────────────────────────────────────────────────────────
# 08-flujo-sfn.tf — Subida → SQS → Lambda → Step Functions (espera del docente duradera).
#
# ESTADO: PROPUESTA, NO APLICADA. La extensión ".pendiente" hace que Terraform NO cargue este archivo. Se validó con
# `terraform validate` (sin tocar AWS) y el flujo completo se probó en LocalStack (ver docs/superpowers/specs/2026-10-01-sqs-stepfunctions-design.md).
#
# QUÉ CREA
#   SQS       cola `prisma-flujo` + DLQ (3 recepciones) y la política que deja escribir a S3.
#   Lambdas   `sfn-starter` (SQS → StartExecution, FUERA de la VPC) y `sfn-invoker` (Step Functions → ALB, DENTRO de la VPC, solo HTTP).
#   Step Fn   máquina `prisma-flujo` (Standard) con la definición de prisma_workflow/statemachine/prisma_flow.asl.json.
#   S3        notificación jobs/ → SQS (REEMPLAZA la que hoy llama a la Lambda `prisma-trigger`) y expiración de 7 días de `state/`.
#
# CÓMO ACTIVARLO (en este orden; el corte es el paso 4)
#   1. Despliega primero la imagen NUEVA del workflow (compatible con ambos caminos; sin SFN_STATE_MACHINE_ARN se comporta como hoy).
#   2. Renombra este archivo a 08-flujo-sfn.tf y corre `terraform plan`. Debe mostrar SOLO recursos nuevos (to add) salvo lo del paso 3.
#   3. En 05-eventos.tf elimina `aws_s3_bucket_notification.workflow` y `aws_lambda_permission.s3_invoca_trigger` (S3 admite una sola
#      configuración de notificaciones por bucket: la de este archivo la reemplaza). La Lambda `trigger` puede quedarse para la reversa.
#   4. `terraform apply`. Ese apply hace el CORTE: desde ese momento las subidas entran por SQS.
#   5. En 03-ecs.tf, `local.env.workflow`, agrega  SFN_STATE_MACHINE_ARN = aws_sfn_state_machine.flujo.arn  y vuelve a aplicar.
#      Sin esa variable el workflow no sabe cancelar ejecuciones (/cancel) ni derivar el ARN.
#
# REVERSA
#   Restaurar `aws_s3_bucket_notification.workflow` (la que llama a la Lambda `prisma-trigger`) y quitar la de este archivo.
#   El camino antiguo (/chat/internal/run) sigue en el código.
#
# DEPENDE DEL LAB (no se pudo comprobar con el lab cerrado)
#   * Que Step Functions esté habilitado en el Learner Lab y que `LabRole` tenga `states:*`, `sqs:*` y `lambda:*`.
#   * El rol de la tarea de ECS (LabRole) necesita `states:SendTaskSuccess/Failure/Heartbeat` y `states:StopExecution`.
# ──────────────────────────────────────────────────────────────────────────────

variable "sfn_fase_timeout_segundos" {
  description = "Tiempo máximo de una fase (A o B)."
  type        = number
  default     = 300
}

variable "sfn_heartbeat_segundos" {
  description = "Una fase sin señales de vida por este tiempo se da por muerta y se reintenta UNA vez."
  type        = number
  default     = 120
}

variable "sfn_hitl_timeout_segundos" {
  description = "Cuánto espera el flujo la decisión del docente antes de expirar (8 min; el cupo por docente vence a los 10)."
  type        = number
  default     = 480
}

# ── SQS ───────────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "flujo_dlq" {
  name                      = "${var.nombre}-flujo-dlq"
  message_retention_seconds = 1209600 # 14 días
}

resource "aws_sqs_queue" "flujo" {
  name                       = "${var.nombre}-flujo"
  visibility_timeout_seconds = 180 # >= 6 veces el timeout de la Lambda starter (30 s)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.flujo_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "flujo" {
  queue_url = aws_sqs_queue.flujo.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "S3EnviaEventos"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.flujo.arn
      Condition = {
        ArnEquals    = { "aws:SourceArn" = local.bucket_workflow_arn }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

# ── S3: notificación hacia SQS y expiración del estado de las fases ───────────
# REEMPLAZA a aws_s3_bucket_notification.workflow de 05-eventos.tf (ver el paso 3 del encabezado).
resource "aws_s3_bucket_notification" "workflow_sqs" {
  bucket = local.bucket_workflow

  queue {
    id            = "${var.nombre}-flujo"
    queue_arn     = aws_sqs_queue.flujo.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "jobs/"
  }

  depends_on = [aws_sqs_queue_policy.flujo, terraform_data.bucket_workflow]
}

# `state/` guarda texto de PACI y planificaciones (datos de menores) entre fases: expira a los 7 días, igual que el TTL de DynamoDB.
resource "aws_s3_bucket_lifecycle_configuration" "workflow_state" {
  bucket = local.bucket_workflow

  rule {
    id     = "expirar-estado-de-fases"
    status = "Enabled"

    filter {
      prefix = "state/"
    }

    expiration {
      days = 7
    }
  }

  depends_on = [terraform_data.bucket_workflow]
}

# ── Lambdas ───────────────────────────────────────────────────────────────────
data "archive_file" "sfn_starter" {
  type        = "zip"
  output_path = "${path.module}/.build/prisma-sfn-starter.zip"

  source {
    content  = file("${path.module}/../prisma_workflow/lambda/sfn_starter.py")
    filename = "lambda_function.py"
  }
}

data "archive_file" "sfn_invoker" {
  type        = "zip"
  output_path = "${path.module}/.build/prisma-sfn-invoker.zip"

  source {
    content  = file("${path.module}/../prisma_workflow/lambda/sfn_invoker.py")
    filename = "lambda_function.py"
  }
}

resource "aws_cloudwatch_log_group" "sfn_starter" {
  name = "/aws/lambda/${var.nombre}-sfn-starter"
}

resource "aws_cloudwatch_log_group" "sfn_invoker" {
  name = "/aws/lambda/${var.nombre}-sfn-invoker"
}

# FUERA de la VPC: necesita llegar a la API pública de Step Functions (las subredes por defecto no dan internet a una Lambda en VPC).
resource "aws_lambda_function" "sfn_starter" {
  function_name = "${var.nombre}-sfn-starter"
  role          = data.aws_iam_role.lab.arn
  runtime       = "python3.12"
  handler       = "lambda_function.handler"
  architectures = ["x86_64"]
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.sfn_starter.output_path
  source_code_hash = data.archive_file.sfn_starter.output_base64sha256

  environment {
    variables = {
      STATE_MACHINE_ARN    = aws_sfn_state_machine.flujo.arn
      FASE_TIMEOUT_SECONDS = tostring(var.sfn_fase_timeout_segundos)
      HEARTBEAT_SECONDS    = tostring(var.sfn_heartbeat_segundos)
      HITL_TIMEOUT_SECONDS = tostring(var.sfn_hitl_timeout_segundos)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.sfn_starter.name
  }
}

# DENTRO de la VPC: llega al ALB interno. Solo HTTP (sin boto3, sin llamadas a APIs de AWS).
resource "aws_lambda_function" "sfn_invoker" {
  function_name = "${var.nombre}-sfn-invoker"
  role          = data.aws_iam_role.lab.arn
  runtime       = "python3.12"
  handler       = "lambda_function.handler"
  architectures = ["x86_64"]
  timeout       = 45
  memory_size   = 128

  filename         = data.archive_file.sfn_invoker.output_path
  source_code_hash = data.archive_file.sfn_invoker.output_base64sha256

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
    log_group  = aws_cloudwatch_log_group.sfn_invoker.name
  }
}

# Un mensaje por invocación y reporte de fallos parciales; como máximo 2 arranques concurrentes
# (acota los ARRANQUES, no los flujos en curso: si hace falta proteger la cuota de Gemini se agrega un semáforo).
resource "aws_lambda_event_source_mapping" "flujo" {
  event_source_arn        = aws_sqs_queue.flujo.arn
  function_name           = aws_lambda_function.sfn_starter.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 2
  }
}

# ── Step Functions (Standard: waitForTaskToken no existe en Express) ──────────
resource "aws_sfn_state_machine" "flujo" {
  name     = "${var.nombre}-flujo"
  role_arn = data.aws_iam_role.lab.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/../prisma_workflow/statemachine/prisma_flow.asl.json", {
    InvokerArn = aws_lambda_function.sfn_invoker.arn
  })
}

output "flujo_state_machine_arn" {
  description = "Agregar a las variables del contenedor `workflow` como SFN_STATE_MACHINE_ARN (paso 5 del encabezado)."
  value       = aws_sfn_state_machine.flujo.arn
}

output "flujo_queue_url" {
  value = aws_sqs_queue.flujo.url
}
