# ──────────────────────────────────────────────────────────────────────────────
# 11-postgres.tf — Base de datos Postgres (RDS) de los microservicios.
#
# En una cuenta nueva `terraform apply` CREA la instancia, su grupo de subredes y la regla de entrada desde ECS.
# (En la cuenta del lab del 2026-10-08 la instancia se había creado a mano por consola, y se trajo al state con
# `terraform import`; el código no lleva bloques `import`, para que funcione igual en una cuenta sin nada.)
#
# DISEÑO
#   * UNA instancia, CUATRO bases (prisma_users, prisma_docs, prisma_perfil, prisma_adminpanel), una por servicio.
#     perfil y adminpanel usan ambos el esquema `public`: si compartieran base, el `db push` de adminpanel borraría
#     las tablas de perfil. Las URLs de cada servicio se arman en 03-ecs.tf (local.database_urls).
#   * Sin acceso público: solo entra el grupo de seguridad del ECS (regla de abajo). No hay subred privada de verdad
#     (la VPC por defecto solo tiene subredes públicas): "privada" significa sin IP pública y sin regla de entrada.
#
# LO QUE TERRAFORM NO HACE (manual en una cuenta nueva, después del apply)
#   1. Crear las bases:  CREATE DATABASE prisma_users; ... prisma_docs; prisma_perfil; prisma_adminpanel; prisma_rag;
#      y en prisma_rag:  CREATE EXTENSION vector;  (RAG normativo; pgvector 0.8.x viene con RDS PostgreSQL 18).
#      Hay un script que abre el RDS solo para tu IP y ejecuta el SQL: scripts/rds_acceso.py (abrir | sql | cerrar).
#   1b. Rol de solo lectura del RAG (el workflow NO usa la clave maestra), con la clave de rag_lector_password:
#      CREATE ROLE rag_lector LOGIN PASSWORD '...';  GRANT CONNECT ON DATABASE prisma_rag TO rag_lector;
#      y en prisma_rag:  GRANT USAGE ON SCHEMA public TO rag_lector;  GRANT SELECT ON documentos, fragmentos TO rag_lector;
#   2. Correr las migraciones: `prisma migrate deploy` en users, docs y perfil, y `prisma db push` en adminpanel.
#   Para ambas hay que abrir la base un momento: publicly_accessible = true y una regla del 5432 desde tu IP /32.
#   Ciérrala al terminar.
#   La instancia tarda ~10 minutos en estar disponible; el servicio ECS puede arrancar antes y reintentar.
#
# SECRETOS: db_password vive en terraform.tfvars (gitignoreado) y en el state. Es una clave de desarrollo del lab.
# ──────────────────────────────────────────────────────────────────────────────

variable "db_username" {
  description = "Usuario administrador de la instancia."
  type        = string
  default     = "postgres"
}

variable "rag_lector_password" {
  description = "Clave del rol de solo lectura `rag_lector` (RAG normativo). El workflow usa este rol, no el maestro."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Clave del usuario administrador. Terraform no la cambia en una instancia adoptada (ver ignore_changes)."
  type        = string
  sensitive   = true
}

# El grupo de seguridad `default` de la VPC por defecto: es el que RDS asignó a la instancia al crearla por consola.
data "aws_security_group" "vpc_default" {
  vpc_id = data.aws_vpc.default.id
  name   = "default"
}

# Todas las subredes por defecto de la VPC (una por zona). Mismo nombre que crea la consola de RDS.
resource "aws_db_subnet_group" "postgres" {
  name        = "default-${data.aws_vpc.default.id}"
  description = "Created from the RDS Management Console"
  subnet_ids  = data.aws_subnets.default.ids
}

resource "aws_db_instance" "postgres" {
  identifier     = "database-1"
  engine         = "postgres"
  engine_version = "18.3"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 1000
  storage_type          = "gp2"
  storage_encrypted     = true

  username = var.db_username
  password = var.db_password

  multi_az            = false
  publicly_accessible = false

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [data.aws_security_group.vpc_default.id]
  parameter_group_name   = "default.postgres18"

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  deletion_protection        = false
  ca_cert_identifier         = "rds-ca-rsa2048-g1"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # Laboratorio: al destruir no se pide snapshot final.
  skip_final_snapshot = true
  apply_immediately   = true

  lifecycle {
    # La clave no se lee de vuelta desde AWS; la versión menor la sube AWS sola (auto_minor_version_upgrade).
    ignore_changes = [password, engine_version]
  }
}

# Entrada al 5432 SOLO desde las tasks de ECS.
resource "aws_vpc_security_group_ingress_rule" "bd_desde_ecs" {
  security_group_id            = data.aws_security_group.vpc_default.id
  referenced_security_group_id = aws_security_group.ecs.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "ECS prisma-app"
}

output "bd_endpoint" {
  description = "Dirección de la instancia Postgres (resuelve a una IP interna de la VPC)."
  value       = aws_db_instance.postgres.address
}
