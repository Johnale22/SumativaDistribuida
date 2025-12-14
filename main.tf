provider "aws" {
  region = "us-east-1"
}

# =============================================================================
# 1. DATOS DE RED Y SISTEMA OPERATIVO
# =============================================================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# =============================================================================
# 2. SEGURIDAD (Firewall)
# =============================================================================
resource "aws_security_group" "web_sg" {
  name        = "proyecto-final-reparado"
  description = "Permitir HTTP y SSH"
  vpc_id      = data.aws_vpc.default.id

  # Puerto 80: Para que el Balanceador y Usuarios entren al Frontend
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Puerto 22: Para que puedas entrar a revisar logs si algo falla
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Salida total permitida (necesario para descargar de Docker Hub)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =============================================================================
# 3. BALANCEADOR DE CARGA (ALB)
# =============================================================================
resource "aws_lb" "mi_alb" {
  name               = "alb-proyecto-final"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "mi_tg" {
  name     = "tg-proyecto-final"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  
  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 20
    matcher             = "200"
  }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.mi_alb.arn
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mi_tg.arn
  }
}

# =============================================================================
# 4. PLANTILLA DE SERVIDORES (Launch Template + Docker)
# =============================================================================
resource "aws_launch_template" "mi_lt" {
  name_prefix   = "lt-docker-app-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  # SCRIPT DE INICIO (User Data) - Versión Mejorada
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Redirigir logs para depuración
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

    echo "Iniciando instalación..."
    yum update -y
    yum install -y docker git
    
    # Iniciar servicio Docker
    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ec2-user
    
    # Esperar a que el socket de Docker esté listo
    echo "Esperando a Docker..."
    sleep 10

    # Instalar Plugin de Docker Compose (Método oficial V2)
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    # Crear carpeta de trabajo
    mkdir -p /app
    cd /app

    # Crear docker-compose.yml dinámicamente
    echo "Creando archivo docker-compose.yml..."
    cat <<EOT > docker-compose.yml
    version: '3'
    services:
      frontend:
        image: Johnal22/proyecto-front:latest   # <--- ¡CAMBIA ESTO!
        ports:
          - "80:80"
        restart: always
        depends_on:
          - backend

      backend:
        image: Johnal22/proyecto-back:latest    # <--- ¡CAMBIA ESTO!
        ports:
          - "5000:5000"
        restart: always
    EOT

    # Iniciar la aplicación
    echo "Levantando contenedores..."
    docker compose up -d
    echo "Despliegue finalizado exitosamente."
  EOF
  )
}

# =============================================================================
# 5. AUTO SCALING GROUP (ASG)
# =============================================================================
resource "aws_autoscaling_group" "mi_asg" {
  name                = "app-asg-produccion" # Nombre fijo para el GitHub Action
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.mi_tg.arn]
  
  # Chequeo de salud basado en el Balanceador
  health_check_type         = "ELB"
  health_check_grace_period = 300 # 5 minutos para dar tiempo a descargar e instalar

  launch_template {
    id      = aws_launch_template.mi_lt.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "App-Docker-Node"
    propagate_at_launch = true
  }
}

# =============================================================================
# 6. OUTPUTS
# =============================================================================
output "url_web" {
  description = "Entra a este link para ver tu proyecto"
  value       = "http://${aws_lb.mi_alb.dns_name}"
}