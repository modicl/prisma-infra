# Cadena de security groups cerrada extremo a extremo:
#   vpclink -> alb (:80) -> ecs (:3010 y :8000)
# La Lambda prisma-trigger también entra al ALB (:80) para llamar
# /chat/internal/run/{id}. Nada abre puertos a 0.0.0.0/0.

resource "aws_security_group" "vpclink" {
  name        = "${var.nombre}-vpclink"
  description = "Origen del trafico desde API Gateway"
  vpc_id      = data.aws_vpc.default.id

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "lambda" {
  name        = "${var.nombre}-lambda"
  description = "Permite al lambda trigger salir"
  vpc_id      = data.aws_vpc.default.id

  # Regla self que quedó de la creación por consola. No hace daño y se
  # conserva para que el plan no muestre diff contra el lab actual.
  ingress {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
    self      = true
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.nombre}-alb"
  description = "Permite entrada solo desde el VPC Link"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Para recibir solo desde el VPC Link"
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.vpclink.id]
  }

  # La Lambda prisma-trigger llama /chat/internal/run/{id} a través del ALB.
  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs" {
  name        = "${var.nombre}-ecs"
  description = "Permite entrada solo desde el ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    protocol        = "tcp"
    from_port       = 3010
    to_port         = 3010
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    protocol        = "tcp"
    from_port       = 8000
    to_port         = 8000
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- ALB interno ------------------------------------------------------------

resource "aws_lb" "alb" {
  name               = "alb-${var.nombre}"
  load_balancer_type = "application"
  internal           = true
  ip_address_type    = "ipv4"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids
}

# Tipo IP: en Fargate no hay instancias que registrar.
resource "aws_lb_target_group" "bff" {
  name        = "tg-${var.nombre}-bff"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  protocol    = "HTTP"
  port        = 3010

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_target_group" "workflow" {
  name        = "tg-${var.nombre}-workflow"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  protocol    = "HTTP"
  port        = 8000

  # Umbral sano más alto: el workflow tarda en arrancar (carga los agentes).
  health_check {
    path                = "/health"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bff.arn
  }
}

# El chat no pasa por el BFF: es la única excepción del sistema.
resource "aws_lb_listener_rule" "chat" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/chat/*", "/feedback/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.workflow.arn
  }
}

# --- VPC Link: el túnel entre API Gateway y el ALB interno -----------------

resource "aws_apigatewayv2_vpc_link" "link" {
  name               = "${var.nombre}-vpclink"
  security_group_ids = [aws_security_group.vpclink.id]
  subnet_ids         = local.subnet_ids
}
