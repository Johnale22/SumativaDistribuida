provider "aws" {
  region = "us-east-1"
}

# --- 1. REDES ---
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter { name = "vpc-id"; values = [data.aws_vpc.default.id] }
}

# --- 2. SEGURIDAD ---
resource "aws_security_group" "web_sg" {
  name        = "security-group-proyecto-final-v2" # Nombre nuevo
  description = "Permitir HTTP y SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 3. BALANCEADOR (ALB) ---
resource "aws_lb" "mi_alb" {
  name               = "alb-proyecto-final-v2"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "mi_tg" {
  name     = "tg-proyecto-final-v2"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path = "/"
    matcher = "200"
    interval = 30
  }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.mi_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.mi_tg.arn }
}

# --- 4. PLANTILLA EC2 (LAUNCH TEMPLATE) ---
resource "aws_launch_template" "mi_lt" {
  name_prefix   = "lt-proyecto-v2-"
  image_id      = "ami-0ebfd81a33f895dd9" # Amazon Linux 2023 (US-EAST-1)
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  # SCRIPT CORREGIDO Y BLINDADO
  user_data = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    
    echo "--- INICIO INSTALACION ---"
    yum update -y
    yum install -y docker git python3-pip
    
    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ec2-user
    
    # Instalar Docker Compose via Python (Más estable)
    pip3 install docker-compose
    
    # Preparar carpeta con permisos correctos
    mkdir -p /app
    
    # Crear el archivo DIRECTAMENTE con el usuario correcto (Johnal22)
    cat <<EOT > /app/docker-compose.yml
    version: '3'
    services:
      frontend:
        image: Johnal22/proyecto-front:latest
        ports:
          - "80:80"
        restart: always
        depends_on:
          - backend

      backend:
        image: Johnal22/proyecto-back:latest
        ports:
          - "5000:5000"
        restart: always
    EOT
    
    # Corregir permisos (La clave del éxito)
    chown -R ec2-user:ec2-user /app
    
    # Ejecutar
    cd /app
    # Intentamos levantar usando la ruta completa
    /usr/local/bin/docker-compose up -d || docker-compose up -d
    
    echo "--- FIN EXITOSO ---"
  EOF
  )
}

# --- 5. AUTO SCALING GROUP ---
resource "aws_autoscaling_group" "mi_asg" {
  name                = "app-asg-produccion"
  desired_capacity    = 1  # Empezamos con 1 para probar rápido
  max_size            = 2
  min_size            = 1
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.mi_tg.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 400

  launch_template {
    id      = aws_launch_template.mi_lt.id
    version = "$Latest"
  }
  
  instance_refresh {
    strategy = "Rolling"
  }
}

output "url_web" { value = "http://${aws_lb.mi_alb.dns_name}" }