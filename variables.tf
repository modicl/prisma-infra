variable "aws_region" {
  description = "Región del lab. El Learner Lab solo habilita us-east-1 y us-west-2."
  type        = string
  default     = "us-east-1"
}

variable "nombre" {
  description = "Prefijo de todos los recursos."
  type        = string
  default     = "prisma"
}

variable "subnet_ids" {
  description = "Subnets para ALB, ECS, VPC Link y Lambda. null = las dos primeras de la VPC por defecto (ordenadas por id). El ALB exige al menos dos AZ distintas."
  type        = list(string)
  default     = null
}

# --- Frontend ---------------------------------------------------------------

variable "front_urls" {
  description = "Orígenes del frontend, sin barra final. De aquí salen las callback/logout URLs de Cognito y el CORS del gateway. La URL de Amplify se conoce recién después del primer apply: segunda pasada."
  type        = list(string)
  default     = ["http://localhost:3002"]
}

variable "github_repo_front" {
  description = "Repo de GitHub del front. Amplify lo conecta con el token de abajo."
  type        = string
  default     = "https://github.com/modicl/prisma-front"
}

variable "github_token" {
  description = "PAT de GitHub con scope repo, solo para que Amplify conecte el repo. En una cuenta nueva la app de GitHub de Amplify se autoriza a mano desde la consola; este token es la alternativa sin clics. null = no conectar."
  type        = string
  sensitive   = true
  default     = null
}

# --- Cognito ----------------------------------------------------------------

variable "cognito_pool_name" {
  description = "Nombre del User Pool. Cambiarlo DESTRUYE el pool (y sus usuarios): por eso es variable y no un literal."
  type        = string
  default     = "prisma-users"
}

variable "cognito_domain_prefix" {
  description = "Prefijo del dominio hosted UI. Único a nivel GLOBAL: en una cuenta nueva hay que cambiarlo, y luego actualizar la redirect URI en Google Console y en Azure."
  type        = string
}

variable "google_client_id" {
  type = string
}

variable "google_client_secret" {
  type      = string
  sensitive = true
}

variable "entra_tenant_id" {
  description = "GUID del tenant de Entra External ID. El issuer SIEMPRE usa el GUID como subdominio, no el nombre del tenant."
  type        = string
}

variable "entra_client_id" {
  type = string
}

variable "entra_client_secret" {
  description = "La columna Value del secreto en Azure, no el Secret ID."
  type        = string
  sensitive   = true
}

variable "allowlist_activa" {
  description = "true = conecta la Lambda prisma-presignup como Pre sign-up trigger (solo entran los correos de allowlist_correos). false = registro abierto, el rol PENDING hace el control."
  type        = bool
  default     = false
}

variable "allowlist_correos" {
  type    = list(string)
  default = []
}

# --- Secretos de la aplicación (van en la task definition) ------------------

variable "supabase_url" {
  description = "Legado: solo la usa el login/register huérfano de ms-users."
  type        = string
  default     = ""
}

variable "supabase_anon_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "supabase_service_role_key" {
  description = "Exclusivo del contenedor users. Nunca va a otro."
  type        = string
  sensitive   = true
  default     = ""
}

variable "internal_token" {
  description = "Compartido entre prisma_workflow y la Lambda prisma-trigger."
  type        = string
  sensitive   = true
}

variable "google_api_key" {
  description = "API key de Gemini para prisma_workflow. Desaparece cuando se migre a Bedrock."
  type        = string
  sensitive   = true
}

# --- ECS --------------------------------------------------------------------

variable "desired_count" {
  description = "Tasks del servicio. Se ignora después del primer apply para que puedas bajarlo a 0 por consola y ahorrar presupuesto sin que Terraform lo vuelva a subir."
  type        = number
  default     = 1
}

variable "task_cpu" {
  type    = number
  default = 2048
}

variable "task_memory" {
  type    = number
  default = 4096
}
