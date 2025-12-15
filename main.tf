terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
    #  version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# =========================================================================
# 1. DATA SOURCES (Información de la red y sistema operativo)
# =========================================================================

# Usamos la VPC por defecto
data "aws_vpc" "default" {
  default = true
}

# Usamos las subredes por defecto de esa VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Buscamos la última imagen de Amazon Linux 2023
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# =========================================================================
# 2. SECURITY GROUP (El Firewall)
# =========================================================================

resource "aws_security_group" "web_sg" {
  name        = "servidor_web_sg_completo"
  description = "Permitir HTTP y SSH"
  vpc_id      = data.aws_vpc.default.id

  # Entrada: HTTP (80)
  ingress {
    description = "Acceso Web"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Entrada: SSH (22)
  ingress {
    description = "Acceso SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

   # Entrada: HTTP (5000)
  ingress {
    description = "Acceso HTTP"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Salida: Todo permitido (para actualizar e instalar paquetes)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =========================================================================
# 3. BALANCEADOR DE CARGA (ALB)
# =========================================================================

resource "aws_lb" "mi_balanceador" {
  name               = "mi-alb-produccion"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "mi_target_group" {
  name     = "mi-tg-web-produccion"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
  }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.mi_balanceador.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mi_target_group.arn
  }
}

# =========================================================================
# 4. PLANTILLA DE LANZAMIENTO (Launch Template)
# =========================================================================

resource "aws_launch_template" "mi_servidor_plantilla" {
  name_prefix   = "mi-servidor-web-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  # Script que se ejecuta al iniciar la máquina (User Data)
  user_data = base64encode(<<-EOF
              #!/bin/bash
              # 1. Instalar Docker y Docker Compose
              yum update -y
              yum install -y docker git
              systemctl start docker
              systemctl enable docker
              usermod -a -G docker ec2-user

              # Instalar Docker Compose (versión plugin)
              mkdir -p /usr/local/lib/docker/cli-plugins/
              curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
              chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

              # 2. Preparar el entorno
              mkdir /home/ec2-user/app
              cd /home/ec2-user/app

              # 3. Crear el archivo docker-compose.yml dinámicamente
              # (Aquí definimos tu Front y Back. Asegúrate de usar TUS imágenes de Docker Hub)
              cat <<EOT >> docker-compose.yml
              version: '3'
              services:
                frontend:
                  image: johnal22/proyecto-front:latest
                  ports:
                    - "80:80"
                  depends_on:
                    - backend
                
                backend:
                  image: johnal22/proyecto-back:latest
                  ports:
                    - "5000:5000"
                  environment:
                    - DB_HOST=algo
              EOT

              # 4. Arrancar la aplicación
              docker compose up -d
              EOF
  )
}

# =========================================================================
# 5. AUTO SCALING GROUP (ASG)
# =========================================================================

resource "aws_autoscaling_group" "mi_asg" {
  name                = "mi-asg-web-prod"
  desired_capacity    = 4
  max_size            = 4
  min_size            = 3
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.mi_target_group.arn]

  # --- Verificar estado ---
  health_check_type         = "ELB"  # Usar el chequeo del Balanceador (más preciso)
  health_check_grace_period = 300    # ¡IMPORTANTE! Esperar 300 seg (5 min) antes de juzgar
  # -------------------------------

  launch_template {
    id      = aws_launch_template.mi_servidor_plantilla.id
    version = "$Latest"
  }

  # Esta etiqueta es CRUCIAL para el Data Source de abajo
  tag {
    key                 = "Name"
    value               = "Instancia-ASG-Web"
    propagate_at_launch = true
  }
}

# =========================================================================
# 6. OUTPUTS AVANZADOS (Lo que pediste extra)
# =========================================================================

# Buscamos las instancias que tengan la etiqueta "Instancia-ASG-Web"
data "aws_instances" "instancias_del_grupo" {
  instance_tags = {
    Name = "Instancia-ASG-Web"
  }

  instance_state_names = ["running", "pending"]
  depends_on           = [aws_autoscaling_group.mi_asg]
}

output "link_del_balanceador" {
  description = "Copia y pega esto en tu navegador"
  value       = "http://${aws_lb.mi_balanceador.dns_name}"
}

output "info_instancias_ids" {
  description = "IDs de los servidores creados"
  value       = data.aws_instances.instancias_del_grupo.ids
}

output "info_instancias_ips_publicas" {
  description = "IPs Públicas de los servidores (si salen vacías, ejecuta 'terraform refresh')"
  value       = data.aws_instances.instancias_del_grupo.public_ips
}

# ---------------------------------------------------------
# 7. POLÍTICA DE ESCALADO AUTOMÁTICO (CPU)
# ---------------------------------------------------------

resource "aws_autoscaling_policy" "escala_por_cpu" {
  name                   = "politica-cpu-50-porciento"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.mi_asg.name
  
  # Importante: Para que esto funcione, asegúrate de que tu ASG tenga tiempo de enfriamiento
  # o deja que Terraform use los valores por defecto.

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    # Aquí defines la regla: "Mantener el CPU al 50%"
    target_value = 50.0 
    
    # Tiempo (segundos) para esperar antes de volver a escalar (evita el efecto "yoyó")
    disable_scale_in = false 
  }
}