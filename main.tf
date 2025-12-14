provider "aws" { region = "us-east-1" }

# --- Red y AMI ---
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter { name = "vpc-id"; values = [data.aws_vpc.default.id] }
}
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name"; values = ["al2023-ami-2023.*-x86_64"] }
}

# --- Seguridad ---
resource "aws_security_group" "web_sg" {
  name        = "sg-proyecto-final"
  vpc_id      = data.aws_vpc.default.id
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

# --- Balanceador (ALB) ---
resource "aws_lb" "mi_alb" {
  name               = "alb-proyecto-final"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "mi_tg" {
  name     = "tg-proyecto-final"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check { path = "/"; matcher = "200"; interval = 20 }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.mi_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.mi_tg.arn }
}

# --- Launch Template (Docker Compose) ---
resource "aws_launch_template" "mi_lt" {
  name_prefix   = "lt-proyecto-docker-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y docker
    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ec2-user

    # Instalar Docker Compose V2
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    # Crear carpeta del proyecto
    mkdir /app
    cd /app

    # Escribir el docker-compose.yml dinámicamente
    cat <<EOT > docker-compose.yml
    version: '3'
    services:
      frontend:
        image: TU_USUARIO_DOCKER/proyecto-front:latest
        ports:
          - "80:80"
        restart: always
        depends_on:
          - backend

      backend:
        image: TU_USUARIO_DOCKER/proyecto-back:latest
        ports:
          - "5000:5000"
        restart: always
    EOT

    # Iniciar la app
    docker compose up -d
  EOF
  )
}

# --- Auto Scaling Group ---
resource "aws_autoscaling_group" "mi_asg" {
  name                = "app-asg-produccion" # Nombre fijo para GitHub Actions
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.mi_tg.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.mi_lt.id
    version = "$Latest"
  }
  
  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 50 }
  }
}

output "url_web" { value = "http://${aws_lb.mi_alb.dns_name}" }