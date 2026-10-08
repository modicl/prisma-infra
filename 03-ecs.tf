# Los seis contenedores van en UNA task: comparten namespace de red y se
# hablan por localhost. Eso reemplaza al service discovery, que el lab no da.

resource "aws_ecr_repository" "repos" {
  for_each = toset([
    "bff-prisma",
    "api/users",
    "api/msdocs",
    "api/adminpanel",
    "api/perfil-alumno",
    "prisma-workflow",
  ])

  name                 = each.key
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name = "/ecs/${var.nombre}-bff"
}

resource "aws_ecs_cluster" "cluster" {
  name = "${var.nombre}-cluster"

  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "cluster" {
  cluster_name       = aws_ecs_cluster.cluster.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

locals {
  # Una base por servicio dentro de la misma instancia: perfil y adminpanel usan ambos el esquema `public`, y el `db push` de
  # adminpanel borraría las tablas de perfil si compartieran base (igual que en el compose local).
  # sslaccept=accept_invalid_certs: el certificado de RDS no está en la cadena de confianza de Prisma (entorno de desarrollo).
  database_urls = {
    for servicio, base in {
      users      = "prisma_users"
      docs       = "prisma_docs"
      perfil     = "prisma_perfil"
      adminpanel = "prisma_adminpanel"
    } : servicio => "postgresql://${var.db_username}:${urlencode(var.db_password)}@${aws_db_instance.postgres.address}:5432/${base}?sslmode=require&sslaccept=accept_invalid_certs"
  }

  cognito_env = {
    COGNITO_REGION       = local.region
    COGNITO_USER_POOL_ID = aws_cognito_user_pool.pool.id
    COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.front.id
  }

  logs = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.ecs.name
      awslogs-region        = local.region
      awslogs-stream-prefix = "ecs"
      awslogs-create-group  = "true"
    }
  }

  # name/value como los espera ECS.
  env = { for c, vars in {
    bff = {
      NODE_ENV               = "production"
      PORT                   = "3010"
      CORS_ORIGIN            = "" # el CORS lo hace API Gateway, no el BFF
      USERS_SERVICE_URL      = "http://localhost:3001"
      DOCS_SERVICE_URL       = "http://localhost:3000"
      ADMINPANEL_SERVICE_URL = "http://localhost:3004"
      PERFIL_SERVICE_URL     = "http://localhost:3005"
    }
    users = merge(local.cognito_env, {
      NODE_ENV                  = "production"
      PORT                      = "3001"
      CORS_ORIGIN               = "http://localhost:3010"
      DATABASE_URL              = local.database_urls.users
      SUPABASE_URL              = var.supabase_url
      SUPABASE_ANON_KEY         = var.supabase_anon_key
      SUPABASE_SERVICE_ROLE_KEY = var.supabase_service_role_key
    })
    docs = merge(local.cognito_env, {
      PORT           = "3000"
      CORS_ORIGIN    = "http://localhost:3010"
      DATABASE_URL   = local.database_urls.docs
      SUPABASE_URL   = var.supabase_url
      AWS_REGION     = local.region
      S3_BUCKET      = local.bucket_workflow
      DYNAMO_TABLE   = aws_dynamodb_table.sessions.name
      INTERNAL_TOKEN = var.internal_token
    })
    adminpanel = {
      PORT              = "3004"
      CORS_ORIGIN       = "http://localhost:3010"
      DATABASE_URL      = local.database_urls.adminpanel
      USERS_SERVICE_URL = "http://localhost:3001/api" # con /api, a diferencia del BFF
      DOCS_SERVICE_URL  = "http://localhost:3000"
    }
    perfil = merge(local.cognito_env, {
      PORT         = "3005"
      CORS_ORIGIN  = "http://localhost:3010"
      DATABASE_URL = local.database_urls.perfil
      SUPABASE_URL = var.supabase_url
    })
    workflow = merge(local.cognito_env, {
      PORT           = "8000"
      AWS_REGION     = local.region
      S3_BUCKET      = local.bucket_workflow
      DYNAMO_TABLE   = aws_dynamodb_table.sessions.name
      INTERNAL_TOKEN = var.internal_token
      SUPABASE_URL   = var.supabase_url
      GOOGLE_API_KEY = var.google_api_key
      # Orquestación por Step Functions: SendTask*, heartbeat y cancelación. Ver 08-flujo-sfn.tf.
      SFN_STATE_MACHINE_ARN = aws_sfn_state_machine.flujo.arn
    })
    } : c => [for k, v in vars : { name = k, value = v }]
  }

  # Las imágenes van por TAG (:latest), no por digest: es lo que asume el
  # deploy-ecr.yml de cada repo (push a :latest + force-redeploy). Con digest,
  # un push nuevo no cambia nada y la task sigue con el código viejo.
  contenedores = [
    { name = "bff", repo = "bff-prisma", port = 3010, essential = true, app_protocol = "http" },
    { name = "users", repo = "api/users", port = 3001, essential = false },
    { name = "docs", repo = "api/msdocs", port = 3000, essential = false },
    { name = "adminpanel", repo = "api/adminpanel", port = 3004, essential = false },
    { name = "perfil", repo = "api/perfil-alumno", port = 3005, essential = false },
    { name = "workflow", repo = "prisma-workflow", port = 8000, essential = false },
  ]
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.nombre}-bff"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)

  # LabRole en AMBOS: la consola propone ecsTaskExecutionRole, que no existe
  # en el Learner Lab.
  execution_role_arn = data.aws_iam_role.lab.arn
  task_role_arn      = data.aws_iam_role.lab.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  # Registrar una revisión nueva no borra la anterior: queda para rollback.
  skip_destroy = true

  container_definitions = jsonencode([
    for c in local.contenedores : {
      name      = c.name
      image     = "${local.ecr_base}/${c.repo}:latest"
      essential = c.essential
      portMappings = [merge({
        name          = "${c.name}-${c.port}-tcp" # el nombre que genera la consola
        containerPort = c.port
        hostPort      = c.port
        protocol      = "tcp"
      }, try({ appProtocol = c.app_protocol }, {}))]
      environment      = local.env[c.name]
      logConfiguration = merge(local.logs, { secretOptions = [] })
      # Listas vacías explícitas: el provider compara el JSON contra lo que
      # devuelve ECS, y ECS las devuelve siempre.
      environmentFiles = []
      mountPoints      = []
      volumesFrom      = []
      systemControls   = []
    }
  ])
}

resource "aws_ecs_service" "app" {
  name             = "${var.nombre}-app"
  cluster          = aws_ecs_cluster.cluster.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  health_check_grace_period_seconds  = 120
  availability_zone_rebalancing      = "ENABLED"

  network_configuration {
    subnets         = local.subnet_ids
    security_groups = [aws_security_group.ecs.id]
    # Sin NAT Gateway en el lab: sin IP pública la task no puede bajar la
    # imagen de ECR y muere con CannotPullContainerError.
    assign_public_ip = true
  }

  # Dos target groups en un servicio: la consola solo deja atar uno.
  load_balancer {
    target_group_arn = aws_lb_target_group.bff.arn
    container_name   = "bff"
    container_port   = 3010
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.workflow.arn
    container_name   = "workflow"
    container_port   = 8000
  }

  lifecycle {
    # Escalar a 0 por consola para ahorrar presupuesto no debe pelear con Terraform.
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.http]
}
